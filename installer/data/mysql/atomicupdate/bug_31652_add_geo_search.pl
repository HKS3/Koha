use Modern::Perl;

return {
    bug_number => "31652",
    description => "Add geo-search: new value for search_field.type enum",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};
        # Do you stuffs here
        $dbh->do(q{ alter table search_field MODIFY COLUMN type enum('','string','date','number','boolean','sum','isbn','stdno','year','callnumber','geo_point') });
        # Print useful stuff here
        say $out "Added new value 'geo_point' to search_field.type enum";
    },
};
