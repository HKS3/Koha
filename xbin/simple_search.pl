use Modern::Perl;

use List::MoreUtils qw( any );

use C4::Koha qw( GetNormalizedISBN );

use Koha::Database;
use Koha::DateUtils qw( dt_from_string );

use base qw(Koha::Object);

use Koha::Acquisition::Orders;
use Koha::ArticleRequests;
use Koha::Biblio::Metadatas;
use Koha::Biblio::ItemGroups;
use Koha::Biblioitems;
use Koha::Checkouts;
use Koha::CirculationRules;
use Koha::Item::Transfer::Limits;
use Koha::Items;
use Koha::Libraries;
use Koha::Old::Checkouts;
use Koha::Recalls;
use Koha::RecordProcessor;
use Koha::Suggestions;
use Koha::Subscriptions;
use Koha::SearchEngine;
use Koha::SearchEngine::Search;
use Koha::SearchEngine::QueryBuilder;


Returns the itemtype for this record.

=cut

sub itemtype {
    my ( $self ) = @_;

    return $self->biblioitem()->itemtype();
}

=head3 holds

my $holds = $biblio->holds();

return the current holds placed on this record

=cut

sub holds {
    my ( $self, $params, $attributes ) = @_;
    $attributes->{order_by} = 'priority' unless exists $attributes->{order_by};
    my $hold_rs = $self->_result->reserves->search( $params, $attributes );
    return Koha::Holds->_new_from_dbic($hold_rs);
}

=head3 current_holds

my $holds = $biblio->current_holds

Return the holds placed on this bibliographic record.
It does not include future holds.

=cut

sub current_holds {
    my ($self) = @_;
    my $dtf = Koha::Database->new->schema->storage->datetime_parser;
    return $self->holds(
        { reservedate => { '<=' => $dtf->format_date(dt_from_string) } } );
}

=head3 biblioitem

my $field = $self->biblioitem()->itemtype

Returns the related Koha::Biblioitem object for this Biblio object

=cut

sub biblioitem {
    my ($self) = @_;

    $self->{_biblioitem} ||= Koha::Biblioitems->find( { biblionumber => $self->biblionumber() } );

    return $self->{_biblioitem};
}

=head3 suggestions

my $suggestions = $self->suggestions

Returns the related Koha::Suggestions object for this Biblio object

=cut

sub suggestions {
    my ($self) = @_;

    my $suggestions_rs = $self->_result->suggestions;
    return Koha::Suggestions->_new_from_dbic( $suggestions_rs );
}

=head3 get_marc_components

  my $components = $self->get_marc_components();

Returns an array of search results data, which are component parts of
this object (MARC21 773 points to this)

=cut

sub get_marc_components {
    my ($self, $max_results) = @_;

    return [] if (C4::Context->preference('marcflavour') ne 'MARC21');

    my ( $searchstr, $sort ) = $self->get_components_query;

    my $components;
    if (defined($searchstr)) {
        my $searcher = Koha::SearchEngine::Search->new({index => $Koha::SearchEngine::BIBLIOS_INDEX});
        my ( $error, $results, $facets );
        eval {
            ( $error, $results, $facets ) = $searcher->search_compat( $searchstr, undef, [$sort], ['biblioserver'], $max_results, 0, undef, undef, 'ccl', 0 );
        };
        if( $error || $@ ) {
            $error //= q{};
            $error .= $@ if $@;
            warn "Warning from search_compat: '$error'";
            $self->add_message(
                {
                    type    => 'error',
                    message => 'component_search',
                    payload => $error,
                }
            );
        }
        $components = $results->{biblioserver}->{RECORDS} if defined($results) && $results->{biblioserver}->{hits};
    }

    return $components // [];
}

=head2 get_components_query

Returns a query which can be used to search for all component parts of MARC21 biblios

=cut

sub get_components_query {
    my ($self) = @_;

    my $builder = Koha::SearchEngine::QueryBuilder->new(
        { index => $Koha::SearchEngine::BIBLIOS_INDEX } );
    my $marc = $self->metadata->record;
    my $component_sort_field = C4::Context->preference('ComponentSortField') // "title";
    my $component_sort_order = C4::Context->preference('ComponentSortOrder') // "asc";
    my $sort = $component_sort_field . "_" . $component_sort_order;

    my $searchstr;
    if ( C4::Context->preference('UseControlNumber') ) {
        my $pf001 = $marc->field('001') || undef;

        if ( defined($pf001) ) {
            $searchstr = "(";
            my $pf003 = $marc->field('003') || undef;

            if ( !defined($pf003) ) {
                # search for 773$w='Host001'
                $searchstr .= "rcn:" . $pf001->data();
            }
            else {
                $searchstr .= "(";
                # search for (773$w='Host001' and 003='Host003') or 773$w='(Host003)Host001'
                $searchstr .= "(rcn:" . $pf001->data() . " AND cni:" . $pf003->data() . ")";
                $searchstr .= " OR rcn:\"" . $pf003->data() . " " . $pf001->data() . "\"";
                $searchstr .= ")";
            }

            # limit to monograph and serial component part records
            $searchstr .= " AND (bib-level:a OR bib-level:b)";
            $searchstr .= ")";
        }
    }
    else {
        my $cleaned_title = $marc->subfield('245', "a");
        $cleaned_title =~ tr|/||;
        $cleaned_title = $builder->clean_search_term($cleaned_title);
        $searchstr = qq#Host-item:("$cleaned_title")#;
    }
    my ($error, $query_str) = $builder->build_query_compat( undef, [$searchstr], undef, undef, [$sort], 0 );
    if( $error ){
        warn $error;
        return;
    }

    return ($query_str, $sort);
}

=head3 subscriptions

my $subscriptions = $self->subscriptions

Returns the related Koha::Subscriptions object for this Biblio object

=cut

sub subscriptions {
    my ($self) = @_;

    $self->{_subscriptions} ||= Koha::Subscriptions->search( { biblionumber => $self->biblionumber } );

    return $self->{_subscriptions};
}

=head3 has_items_waiting_or_intransit

my $itemsWaitingOrInTransit = $biblio->has_items_waiting_or_intransit

Tells if this bibliographic record has items waiting or in transit.

=cut

sub has_items_waiting_or_intransit {
    my ( $self ) = @_;

    if ( Koha::Holds->search({ biblionumber => $self->id,
                               found => ['W', 'T'] })->count ) {
        return 1;
    }

    foreach my $item ( $self->items->as_list ) {
        return 1 if $item->get_transfer;
    }

    return 0;
}

=head2 get_coins

my $coins = $biblio->get_coins;

Returns the COinS (a span) which can be included in a biblio record

=cut

sub get_coins {
    my ( $self ) = @_;

    my $record = $self->metadata->record;

    my $pos7 = substr $record->leader(), 7, 1;
    my $pos6 = substr $record->leader(), 6, 1;
    my $mtx;
    my $genre;
    my ( $aulast, $aufirst ) = ( '', '' );
    my @authors;
    my $title;
    my $hosttitle;
    my $pubyear   = '';
    my $isbn      = '';
    my $issn      = '';
    my $publisher = '';
    my $pages     = '';
    my $titletype = '';

    # For the purposes of generating COinS metadata, LDR/06-07 can be
    # considered the same for UNIMARC and MARC21
    my $fmts6 = {
        'a' => 'book',
        'b' => 'manuscript',
        'c' => 'book',
        'd' => 'manuscript',
        'e' => 'map',
        'f' => 'map',
        'g' => 'film',
        'i' => 'audioRecording',
        'j' => 'audioRecording',
        'k' => 'artwork',
        'l' => 'document',
        'm' => 'computerProgram',
        'o' => 'document',
        'r' => 'document',
    };
    my $fmts7 = {
        'a' => 'journalArticle',
        's' => 'journal',
    };

    $genre = $fmts6->{$pos6} ? $fmts6->{$pos6} : 'book';

    if ( $genre eq 'book' ) {
            $genre = $fmts7->{$pos7} if $fmts7->{$pos7};
    }

    ##### We must transform mtx to a valable mtx and document type ####
    if ( $genre eq 'book' ) {
            $mtx = 'book';
            $titletype = 'b';
    } elsif ( $genre eq 'journal' ) {
            $mtx = 'journal';
            $titletype = 'j';
    } elsif ( $genre eq 'journalArticle' ) {
            $mtx   = 'journal';
            $genre = 'article';
            $titletype = 'a';
    } else {
            $mtx = 'dc';
    }

    if ( C4::Context->preference("marcflavour") eq "UNIMARC" ) {

        # Setting datas
        $aulast  = $record->subfield( '700', 'a' ) || '';
        $aufirst = $record->subfield( '700', 'b' ) || '';
        push @authors, "$aufirst $aulast" if ($aufirst or $aulast);

        # others authors
        if ( $record->field('200') ) {
            for my $au ( $record->field('200')->subfield('g') ) {
                push @authors, $au;
            }
        }

        $title     = $record->subfield( '200', 'a' );
        my $subfield_210d = $record->subfield('210', 'd');
        if ($subfield_210d and $subfield_210d =~ /(\d{4})/) {
            $pubyear = $1;
        }
        $publisher = $record->subfield( '210', 'c' ) || '';
        $isbn      = $record->subfield( '010', 'a' ) || '';
        $issn      = $record->subfield( '011', 'a' ) || '';
    } else {

        # MARC21 need some improve

        # Setting datas
        if ( $record->field('100') ) {
            push @authors, $record->subfield( '100', 'a' );
        }

        # others authors
        if ( $record->field('700') ) {
            for my $au ( $record->field('700')->subfield('a') ) {
                push @authors, $au;
            }
        }
        $title = $record->field('245');
        $title &&= $title->as_string('ab');
        if ($titletype eq 'a') {
            $pubyear   = $record->field('008') || '';
            $pubyear   = substr($pubyear->data(), 7, 4) if $pubyear;
            $isbn      = $record->subfield( '773', 'z' ) || '';
            $issn      = $record->subfield( '773', 'x' ) || '';
            $hosttitle = $record->subfield( '773', 't' ) || $record->subfield( '773', 'a') || q{};
            my @rels = $record->subfield( '773', 'g' );
            $pages = join(', ', @rels);
        } else {
            $pubyear   = $record->subfield( '260', 'c' ) || '';
            $publisher = $record->subfield( '260', 'b' ) || '';
            $isbn      = $record->subfield( '020', 'a' ) || '';
            $issn      = $record->subfield( '022', 'a' ) || '';
        }

    }

    my @params = (
        [ 'ctx_ver', 'Z39.88-2004' ],
        [ 'rft_val_fmt', "info:ofi/fmt:kev:mtx:$mtx" ],
        [ ($mtx eq 'dc' ? 'rft.type' : 'rft.genre'), $genre ],
        [ "rft.${titletype}title", $title ],
    );

    # rft.title is authorized only once, so by checking $titletype
    # we ensure that rft.title is not already in the list.
    if ($hosttitle and $titletype) {
        push @params, [ 'rft.title', $hosttitle ];
    }

    push @params, (
        [ 'rft.isbn', $isbn ],
        [ 'rft.issn', $issn ],
    );

    # If it's a subscription, these informations have no meaning.
    if ($genre ne 'journal') {
        push @params, (
            [ 'rft.aulast', $aulast ],
            [ 'rft.aufirst', $aufirst ],
            (map { [ 'rft.au', $_ ] } @authors),
            [ 'rft.pub', $publisher ],
            [ 'rft.date', $pubyear ],
            [ 'rft.pages', $pages ],
        );
    }

    my $coins_value = join( '&amp;',
        map { $$_[1] ? $$_[0] . '=' . uri_escape_utf8( $$_[1] ) : () } @params );

    return $coins_value;
}

=head2 get_openurl

my $url = $biblio->get_openurl;

Returns url for OpenURL resolver set in OpenURLResolverURL system preference

=cut

sub get_openurl {
    my ( $self ) = @_;

    my $OpenURLResolverURL = C4::Context->preference('OpenURLResolverURL');

    if ($OpenURLResolverURL) {
        my $uri = URI->new($OpenURLResolverURL);

        if (not defined $uri->query) {
            $OpenURLResolverURL .= '?';
        } else {
            $OpenURLResolverURL .= '&amp;';
        }
        $OpenURLResolverURL .= $self->get_coins;
    }

    return $OpenURLResolverURL;
}

=head3 is_serial

my $serial = $biblio->is_serial

Return boolean true if this bibbliographic record is continuing resource

=cut

sub is_serial {
    my ( $self ) = @_;

    return 1 if $self->serial;

    my $record = $self->metadata->record;
    return 1 if substr($record->leader, 7, 1) eq 's';

    return 0;
}

=head3 custom_cover_image_url

my $image_url = $biblio->custom_cover_image_url

Return the specific url of the cover image for this bibliographic record.
It is built regaring the value of the system preference CustomCoverImagesURL

=cut

sub custom_cover_image_url {
    my ( $self ) = @_;
    my $url = C4::Context->preference('CustomCoverImagesURL');
    if ( $url =~ m|{isbn}| ) {
        my $isbn = $self->biblioitem->isbn;
        return unless $isbn;
        $url =~ s|{isbn}|$isbn|g;
    }
    if ( $url =~ m|{normalized_isbn}| ) {
        my $normalized_isbn = C4::Koha::GetNormalizedISBN($self->biblioitem->isbn);
        return unless $normalized_isbn;
        $url =~ s|{normalized_isbn}|$normalized_isbn|g;
    }
    if ( $url =~ m|{issn}| ) {
        my $issn = $self->biblioitem->issn;
        return unless $issn;
        $url =~ s|{issn}|$issn|g;
    }

    my $re = qr|{(?<field>\d{3})(\$(?<subfield>.))?}|;
    if ( $url =~ $re ) {
        my $field = $+{field};
        my $subfield = $+{subfield};
        my $marc_record = $self->metadata->record;
        my $value;
        if ( $subfield ) {
            $value = $marc_record->subfield( $field, $subfield );
        } else {
            my $controlfield = $marc_record->field($field);
            $value = $controlfield->data() if $controlfield;
        }
        return unless $value;
        $url =~ s|$re|$value|;
    }

    return $url;
}

=head3 cover_images

Return the cover images associated with this biblio.

=cut

sub cover_images {
    my ( $self ) = @_;

    my $cover_images_rs = $self->_result->cover_images;
    return unless $cover_images_rs;
    return Koha::CoverImages->_new_from_dbic($cover_images_rs);
}

=head3 get_marc_notes

    $marcnotesarray = $biblio->get_marc_notes({ opac => 1 });

Get all notes from the MARC record and returns them in an array.
The notes are stored in different fields depending on MARC flavour.
MARC21 5XX $u subfields receive special attention as they are URIs.

=cut

sub get_marc_notes {
    my ( $self, $params ) = @_;

    my $marcflavour = C4::Context->preference('marcflavour');
    my $opac = $params->{opac} // '0';
    my $interface = $params->{opac} ? 'opac' : 'intranet';

    my $record = $params->{record} // $self->metadata->record;
    my $record_processor = Koha::RecordProcessor->new(
        {
            filters => [ 'ViewPolicy', 'ExpandCodedFields' ],
            options => {
                interface     => $interface,
                frameworkcode => $self->frameworkcode
            }
        }
    );
    $record_processor->process($record);

    my $scope = $marcflavour eq "UNIMARC"? '3..': '5..';
    #MARC21 specs indicate some notes should be private if first indicator 0
    my %maybe_private = (
        541 => 1,
        542 => 1,
        561 => 1,
        583 => 1,
        590 => 1
    );

    my %hiddenlist = map { $_ => 1 }
        split( /,/, C4::Context->preference('NotesToHide'));

    my @marcnotes;
    foreach my $field ( $record->field($scope) ) {
        my $tag = $field->tag();
        next if $hiddenlist{ $tag };
        next if $opac && $maybe_private{$tag} && !$field->indicator(1);
        if( $marcflavour ne 'UNIMARC' && $field->subfield('u') ) {
            # Field 5XX$u always contains URI
            # Examples: 505u, 506u, 510u, 514u, 520u, 530u, 538u, 540u, 542u, 552u, 555u, 561u, 563u, 583u
            # We first push the other subfields, then all $u's separately
            # Leave further actions to the template (see e.g. opac-detail)
            my $othersub =
                join '', ( 'a' .. 't', 'v' .. 'z', '0' .. '9' ); # excl 'u'
            push @marcnotes, { marcnote => $field->as_string($othersub) };
            foreach my $sub ( $field->subfield('u') ) {
                $sub =~ s/^\s+|\s+$//g; # trim
                push @marcnotes, { marcnote => $sub };
            }
        } else {
            push @marcnotes, { marcnote => $field->as_string() };
        }
    }
    return \@marcnotes;
}

=head3 get_marc_authors

    my $authors = $biblio->get_marc_authors;

Get all authors from the MARC record and returns them in an array.
The authors are stored in different fields depending on MARC flavour

=cut

sub get_marc_authors {
    my ( $self, $params ) = @_;

    my ( $mintag, $maxtag, $fields_filter );
    my $marcflavour = C4::Context->preference('marcflavour');

    # tagslib useful only for UNIMARC author responsibilities
    my $tagslib;
    if ( $marcflavour eq "UNIMARC" ) {
        $tagslib = C4::Biblio::GetMarcStructure( 1, $self->frameworkcode, { unsafe => 1 });
        $mintag = "700";
        $maxtag = "712";
        $fields_filter = '7..';
    } else { # marc21/normarc
        $mintag = "700";
        $maxtag = "720";
        $fields_filter = '7..';
    }

    my @marcauthors;
    my $AuthoritySeparator = C4::Context->preference('AuthoritySeparator');

    foreach my $field ( $self->metadata->record->field($fields_filter) ) {
        next unless $field->tag() >= $mintag && $field->tag() <= $maxtag;
        my @subfields_loop;
        my @link_loop;
        my @subfields  = $field->subfields();
        my $count_auth = 0;

        # if there is an authority link, build the link with Koha-Auth-Number: subfield9
        my $subfield9 = $field->subfield('9');
        if ($subfield9) {
            my $linkvalue = $subfield9;
            $linkvalue =~ s/(\(|\))//g;
            @link_loop = ( { 'limit' => 'an', 'link' => $linkvalue } );
        }

        # other subfields
        my $unimarc3;
        for my $authors_subfield (@subfields) {
            next if ( $authors_subfield->[0] eq '9' );

            # unimarc3 contains the $3 of the author for UNIMARC.
            # For french academic libraries, it's the "ppn", and it's required for idref webservice
            $unimarc3 = $authors_subfield->[1] if $marcflavour eq 'UNIMARC' and $authors_subfield->[0] =~ /3/;

            # don't load unimarc subfields 3, 5
            next if ( $marcflavour eq 'UNIMARC' and ( $authors_subfield->[0] =~ /3|5/ ) );

            my $code = $authors_subfield->[0];
            my $value        = $authors_subfield->[1];
            my $linkvalue    = $value;
            $linkvalue =~ s/(\(|\))//g;
            # UNIMARC author responsibility
            if ( $marcflavour eq 'UNIMARC' and $code eq '4' ) {
                $value = C4::Biblio::GetAuthorisedValueDesc( $field->tag(), $code, $value, '', $tagslib );
                $linkvalue = "($value)";
            }
            # if no authority link, build a search query
            unless ($subfield9) {
                push @link_loop, {
                    limit    => 'au',
                    'link'   => $linkvalue,
                    operator => (scalar @link_loop) ? ' AND ' : undef
                };
            }
            my @this_link_loop = @link_loop;
            # do not display $0
            unless ( $code eq '0') {
                push @subfields_loop, {
                    tag       => $field->tag(),
                    code      => $code,
                    value     => $value,
                    link_loop => \@this_link_loop,
                    separator => (scalar @subfields_loop) ? $AuthoritySeparator : ''
                };
            }
        }
        push @marcauthors, {
            MARCAUTHOR_SUBFIELDS_LOOP => \@subfields_loop,
            authoritylink => $subfield9,
            unimarc3 => $unimarc3
        };
    }
    return \@marcauthors;
}

=head3 to_api

    my $json = $biblio->to_api;

Overloaded method that returns a JSON representation of the Koha::Biblio object,
suitable for API output. The related Koha::Biblioitem object is merged as expected
on the API.

=cut

sub to_api {
    my ($self, $args) = @_;

    my $response = $self->SUPER::to_api( $args );
    my $biblioitem = $self->biblioitem->to_api;

    return { %$response, %$biblioitem };
}

=head3 to_api_mapping

This method returns the mapping for representing a Koha::Biblio object
on the API.

=cut

sub to_api_mapping {
    return {
        biblionumber     => 'biblio_id',
        frameworkcode    => 'framework_id',
        unititle         => 'uniform_title',
        seriestitle      => 'series_title',
        copyrightdate    => 'copyright_date',
        datecreated      => 'creation_date'
    };
}

=head3 get_marc_host

    $host = $biblio->get_marc_host;
    # OR:
    ( $host, $relatedparts ) = $biblio->get_marc_host;

    Returns host biblio record from MARC21 773 (undef if no 773 present).
    It looks at the first 773 field with MARCorgCode or only a control
    number. Complete $w or numeric part is used to search host record.
    The optional parameter no_items triggers a check if $biblio has items.
    If there are, the sub returns undef.
    Called in list context, it also returns 773$g (related parts).

=cut

sub get_marc_host {
    my ($self, $params) = @_;
    my $no_items = $params->{no_items};
    return if C4::Context->preference('marcflavour') eq 'UNIMARC'; # TODO
    return if $params->{no_items} && $self->items->count > 0;

    my $record;
    eval { $record = $self->metadata->record };
    return if !$record;

    # We pick the first $w with your MARCOrgCode or the first $w that has no
    # code (between parentheses) at all.
    my $orgcode = C4::Context->preference('MARCOrgCode') // q{};
    my $hostfld;
    foreach my $f ( $record->field('773') ) {
        my $w = $f->subfield('w') or next;
        if( $w =~ /^\($orgcode\)\s*(\d+)/i or $w =~ /^\d+/ ) {
            $hostfld = $f;
            last;
        }
    }
    return if !$hostfld;
    my $rcn = $hostfld->subfield('w');

    # Look for control number with/without orgcode
    my $engine = Koha::SearchEngine::Search->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX });
    my $bibno;
    for my $try (1..2) {
        my ( $error, $results, $total_hits ) = $engine->simple_search_compat( 'Control-number='.$rcn, 0,1 );
        if( !$error and $total_hits == 1 ) {
            $bibno = $engine->extract_biblionumber( $results->[0] );
            last;
        }
        # Add or remove orgcode for second try
        if( $try == 1 && $rcn =~ /\)\s*(\d+)/ ) {
            $rcn = $1; # number only
        } elsif( $try == 1 && $rcn =~ /^\d+/ ) {
            $rcn = "($orgcode)$rcn";
        } else {
            last;
        }
    }
    if( $bibno ) {
        my $host = Koha::Biblios->find($bibno) or return;
        return wantarray ? ( $host, $hostfld->subfield('g') ) : $host;
    }
}

=head3 recalls

    my $recalls = $biblio->recalls;

Return recalls linked to this biblio

=cut

sub recalls {
    my ( $self ) = @_;
    return Koha::Recalls->_new_from_dbic( scalar $self->_result->recalls );
}

=head3 can_be_recalled

    my @items_for_recall = $biblio->can_be_recalled({ patron => $patron_object });

Does biblio-level checks and returns the items attached to this biblio that are available for recall

=cut

sub can_be_recalled {
    my ( $self, $params ) = @_;

    return 0 if !( C4::Context->preference('UseRecalls') );

    my $patron = $params->{patron};

    my $branchcode = C4::Context->userenv->{'branch'};
    if ( C4::Context->preference('CircControl') eq 'PatronLibrary' and $patron ) {
        $branchcode = $patron->branchcode;
    }

    my @all_items = Koha::Items->search({ biblionumber => $self->biblionumber })->as_list;

    # if there are no available items at all, no recall can be placed
    return 0 if ( scalar @all_items == 0 );

    my @itemtypes;
    my @itemnumbers;
    my @items;
    my @all_itemnumbers;
    foreach my $item ( @all_items ) {
        push( @all_itemnumbers, $item->itemnumber );
        if ( $item->can_be_recalled({ patron => $patron }) ) {
            push( @itemtypes, $item->effective_itemtype );
            push( @itemnumbers, $item->itemnumber );
            push( @items, $item );
        }
    }

    # if there are no recallable items, no recall can be placed
    return 0 if ( scalar @items == 0 );

    # Check the circulation rule for each relevant itemtype for this biblio
    my ( @recalls_allowed, @recalls_per_record, @on_shelf_recalls );
    foreach my $itemtype ( @itemtypes ) {
        my $rule = Koha::CirculationRules->get_effective_rules({
            branchcode => $branchcode,
            categorycode => $patron ? $patron->categorycode : undef,
            itemtype => $itemtype,
            rules => [
                'recalls_allowed',
                'recalls_per_record',
                'on_shelf_recalls',
            ],
        });
        push( @recalls_allowed, $rule->{recalls_allowed} ) if $rule;
        push( @recalls_per_record, $rule->{recalls_per_record} ) if $rule;
        push( @on_shelf_recalls, $rule->{on_shelf_recalls} ) if $rule;
    }
    my $recalls_allowed = (sort {$b <=> $a} @recalls_allowed)[0]; # take highest
    my $recalls_per_record = (sort {$b <=> $a} @recalls_per_record)[0]; # take highest
    my %on_shelf_recalls_count = ();
    foreach my $count ( @on_shelf_recalls ) {
        $on_shelf_recalls_count{$count}++;
    }
    my $on_shelf_recalls = (sort {$on_shelf_recalls_count{$b} <=> $on_shelf_recalls_count{$a}} @on_shelf_recalls)[0]; # take most common

    # check recalls allowed has been set and is not zero
    return 0 if ( !defined($recalls_allowed) || $recalls_allowed == 0 );

    if ( $patron ) {
        # check borrower has not reached open recalls allowed limit
        return 0 if ( $patron->recalls->filter_by_current->count >= $recalls_allowed );

        # check borrower has not reached open recalls allowed per record limit
        return 0 if ( $patron->recalls->filter_by_current->search({ biblio_id => $self->biblionumber })->count >= $recalls_per_record );

        # check if any of the items under this biblio are already checked out by this borrower
        return 0 if ( Koha::Checkouts->search({ itemnumber => [ @all_itemnumbers ], borrowernumber => $patron->borrowernumber })->count > 0 );
    }

    # check item availability
    my $checked_out_count = 0;
    foreach (@items) {
        if ( Koha::Checkouts->search({ itemnumber => $_->itemnumber })->count > 0 ){ $checked_out_count++; }
    }

    # can't recall if on shelf recalls only allowed when all unavailable, but items are still available for checkout
    return 0 if ( $on_shelf_recalls eq 'all' && $checked_out_count < scalar @items );

    # can't recall if no items have been checked out
    return 0 if ( $checked_out_count == 0 );

    # can recall
    return @items;
}

=head2 Internal methods

=head3 type

=cut

sub _type {
    return 'Biblio';
}

=head1 AUTHOR

Kyle M Hall <kyle@bywatersolutions.com>

=cut

1;
