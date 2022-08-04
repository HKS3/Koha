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


use Data::Dumper;
my $records =  get_marc_components(1);

printf ("%s\n", $records->[0]->field('245')->subfield("a"));

sub get_marc_components {
    my ($max_results) = @_;

    return [] if (C4::Context->preference('marcflavour') ne 'MARC21');

    my ( $searchstr, $sort ) = get_components_query();

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
        }
        $components = $results->{biblioserver}->{RECORDS} if defined($results) && $results->{biblioserver}->{hits};
    }

    return $components // [];
}


sub get_components_query {

    my $builder = Koha::SearchEngine::QueryBuilder->new(
        { index => $Koha::SearchEngine::BIBLIOS_INDEX } );
   #  my $marc = $self->metadata->record;
    my $component_sort_field = C4::Context->preference('ComponentSortField') // "title";
    my $component_sort_order = C4::Context->preference('ComponentSortOrder') // "asc";
    my $sort = $component_sort_field . "_" . $component_sort_order;

    my $searchstr;
    my $cleaned_title = "perl";
    $cleaned_title =~ tr|/||;
    $cleaned_title = $builder->clean_search_term($cleaned_title);
    $searchstr = "$cleaned_title";
   
    my ($error, $query_str) = $builder->build_query_compat( undef, [$searchstr], undef, undef, [$sort], 0 );
    if( $error ){
        warn $error;
        return;
    }
    return ($query_str, $sort);
}


1;
