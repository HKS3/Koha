#!/usr/bin/perl

# Converted to new plugin style (Bug 13437)

# Copyright 2000-2002 Katipo Communications
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

my $builder = sub {
    my ( $params ) = @_;
    my $function_name = $params->{id};

return qq|<script>
function Change$function_name(event) {
    var v = \$('#'+event.data.id).val();

    var tag_target  = document.querySelectorAll('[id^=\"tag_773_subfield_q\"]');
    var tag_target2 = document.querySelectorAll('[id^=\"tag_830_subfield_v\"]');

    if (tag_target.length) {
        \$('#'+tag_target[0].id).val(v);
    } else if (tag_target2.length) {
        \$('#'+tag_target2[0].id).val(v);
    } else {
        alert('Framework Error, missing target field');
    }
}

</script>
|;
};

return { builder => $builder };

__END__

Wenn ins das Feld 490v die Bandnummer eingetragen wird, wird automatisch der gleiche Inhalt in das Feld 773q übertragen

Wenn ins das Feld 490v die Bandnummer eingetragen wird, wird automatisch der gleiche Inhalt in das Feld 830v übertraeng
