package Koha::Recalls;

# Copyright 2020 Aleisha Amohia <aleisha@catalyst.net.nz>
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Koha::Database;
use Koha::Recall;
use Koha::DateUtils qw( dt_from_string );

use C4::Stats qw( UpdateStats );

use base qw(Koha::Objects);

=head1 NAME

Koha::Recalls - Koha Recalls Object set class

=head1 API

=head2 Class methods

=head3 filter_by_current

    my $current_recalls = $recalls->filter_by_current;

Returns a new resultset, filtering out finished recalls.

=cut

sub filter_by_current {
    my ($self) = @_;

    return $self->search(
        {
            status => [
                'in_transit',
                'overdue',
                'requested',
                'waiting',
            ]
        }
    );
}

=head3 filter_by_finished

    my $finished_recalls = $recalls->filter_by_finished;

Returns a new resultset, filtering out current recalls.

=cut

sub filter_by_finished {
    my ($self) = @_;

    return $self->search(
        {
            status => [
                'cancelled',
                'expired',
                'fulfilled',
            ]
        }
    );
}

=head3 add_recall

    my ( $recall, $due_interval, $due_date ) = Koha::Recalls->add_recall({
        patron => $patron_object,
        biblio => $biblio_object,
        branchcode => $branchcode,
        item => $item_object,
        expirationdate => $expirationdate,
        interface => 'OPAC',
    });

Add a new requested recall. We assume at this point that a recall is allowed to be placed on this item or biblio. We are past the checks and are now doing the recall.
Interface param is either OPAC or INTRANET
Send a RETURN_RECALLED_ITEM notice.
Add statistics and logs.
#FIXME: Add recallnotes and priority when staff-side recalls is added

=cut

sub add_recall {
    my ( $self, $params ) = @_;

    my $patron = $params->{patron};
    my $biblio = $params->{biblio};
    return if ( !defined($patron) or !defined($biblio) );
    my $branchcode = $params->{branchcode};
    $branchcode ||= $patron->branchcode;
    my $item = $params->{item};
    my $itemnumber = $item ? $item->itemnumber : undef;
    my $expirationdate = $params->{expirationdate};
    my $interface = $params->{interface};

    if ( $expirationdate ){
        my $now = dt_from_string;
        $expirationdate = dt_from_string($expirationdate)->set({ hour => $now->hour, minute => $now->minute, second => $now->second });
    }

    my $recall_request = Koha::Recall->new({
        borrowernumber => $patron->borrowernumber,
        recalldate => dt_from_string(),
        biblionumber => $biblio->biblionumber,
        branchcode => $branchcode,
        status => 'requested',
        itemnumber => defined $itemnumber ? $itemnumber : undef,
        expirationdate => $expirationdate,
        item_level_recall => defined $itemnumber ? 1 : 0,
    })->store;

    if (defined $recall_request->recall_id){ # successful recall
        my $recall = Koha::Recalls->find( $recall_request->recall_id );

        # get checkout and adjust due date based on circulation rules
        my $checkout = $recall->checkout;
        my $recall_due_date_interval = Koha::CirculationRules->get_effective_rule({
            categorycode => $checkout->patron->categorycode,
            itemtype => $checkout->item->effective_itemtype,
            branchcode => $branchcode,
            rule_name => 'recall_due_date_interval',
        });
        my $due_interval = defined $recall_due_date_interval ? $recall_due_date_interval->rule_value : 5;
        my $timestamp = dt_from_string( $recall->timestamp );
        my $due_date = $timestamp->add( days => $due_interval );
        $checkout->update({ date_due => $due_date });

        # get itemnumber of most relevant checkout if a biblio-level recall
        unless ( $recall->item_level_recall ) { $itemnumber = $checkout->itemnumber; }

        # send notice to user with recalled item checked out
        my $letter = C4::Letters::GetPreparedLetter (
            module => 'circulation',
            letter_code => 'RETURN_RECALLED_ITEM',
            branchcode => $recall->branchcode,
            tables => {
                biblio => $biblio->biblionumber,
                borrowers => $checkout->borrowernumber,
                items => $itemnumber,
                issues => $itemnumber,
            },
        );

        C4::Message->enqueue( $letter, $checkout->patron->unblessed, 'email' );

        $item = Koha::Items->find( $itemnumber );
        # add to statistics table
        UpdateStats({
            branch => C4::Context->userenv->{'branch'},
            type => 'recall',
            itemnumber => $itemnumber,
            borrowernumber => $recall->borrowernumber,
            itemtype => $item->effective_itemtype,
            ccode => $item->ccode,
        });

        # add action log
        C4::Log::logaction( 'RECALLS', 'CREATE', $recall->recall_id, "Recall requested by borrower #" . $recall->borrowernumber, $interface ) if ( C4::Context->preference('RecallsLog') );

        return ( $recall, $due_interval, $due_date );
    }

    # unable to add recall
    return;
}

=head3 move_recall

    my $message = Koha::Recalls->move_recall({
        recall_id = $recall_id,
        action => $action,
        item => $item_object,
        borrowernumber => $borrowernumber,
    });

A patron is attempting to check out an item that has been recalled by another patron.
If the recall is requested/overdue, they have the option of cancelling the recall.
If the recall is waiting, they also have the option of reverting the waiting status.

We can also fulfill the recall here if the recall is placed by this borrower.

recall_id = ID of the recall to perform the action on
action = either cancel or revert
item = item object that the patron is attempting to check out
borrowernumber = borrowernumber of the patron that is attemptig to check out

=cut

sub move_recall {
    my ( $self, $params ) = @_;

    my $recall_id = $params->{recall_id};
    my $action = $params->{action};
    return 'no recall_id provided' if ( !defined $recall_id );
    my $item = $params->{item};
    my $borrowernumber = $params->{borrowernumber};

    my $message = 'no action provided';

    if ( $action and $action eq 'cancel' ) {
        my $recall = Koha::Recalls->find( $recall_id );
        $recall->set_cancelled;
        $message = 'cancelled';
    } elsif ( $action and $action eq 'revert' ) {
        my $recall = Koha::Recalls->find( $recall_id );
        $recall->revert_waiting;
        $message = 'reverted';
    }

    if ( $message eq 'no action provided' and $item and $item->biblionumber and $borrowernumber ) {
        # move_recall was not called to revert or cancel, but was called to fulfill
        my $recall = Koha::Recalls->search(
            {
                borrowernumber => $borrowernumber,
                biblionumber   => $item->biblionumber,
                itemnumber     => [ $item->itemnumber, undef ],
                old            => 0,
            },
            { order_by => { -asc => 'recalldate' } }
        )->next;
        if ( $recall ) {
            $recall->set_fulfilled;
            $message = 'fulfilled';
        }
    }

    return $message;
}

=head2 Internal methods

=head3 _type

=cut

sub _type {
    return 'Recall';
}

=head3 object_class

=cut

sub object_class {
    return 'Koha::Recall';
}

1;