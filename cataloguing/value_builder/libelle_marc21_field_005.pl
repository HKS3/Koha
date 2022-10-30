#!/usr/bin/perl

# Copyright 2020 hks3

# TODO: install via docker-compose and bare-metal
#       this file has to be copied to /usr/share/koha/intranet/cgi-bin/cataloguing/value_builder/libelle_marc21_field_001.pl
# TODO: add SQL snippet to enable in config
#       manual: http://intranet.libelle:8050/cgi-bin/koha/admin/marc_subfields_structure.pl?op=add_form&tagfield=001&frameworkcode=BKS#sub%40field
#       Other Options: Plugin = libelle_marc21_field_001.pl

use Modern::Perl;

my $builder = sub {
    my ( $params ) = @_;
    my $function_name = $params->{id};

    # find today's date
    my @a= (localtime) [5,4,3,2,1,0]; $a[0]+=1900; $a[1]++;
    my $date = sprintf("%4d%02d%02d%02d%02d%04.1f",@a);

    my $res  = <<'EOJS';
<script type="text/javascript">
//<![CDATA[

$(document).ready(function() {
    if(!document.getElementById('%id%').value){
        document.getElementById('%id%').value = '%val%';
    }
});

//]]>
</script>

EOJS

    $res=~s/%id%/$function_name/g;
    $res=~s/%val%/$date/g;

    return $res;
};

return { builder => $builder };
