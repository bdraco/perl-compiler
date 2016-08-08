package B::SPECIAL;

use strict;
use B qw( @specialsv_name);

sub save {
    my ( $sv, $fullname ) = @_;

    my $sym = $specialsv_name[$$sv];
    if ( !defined($sym) ) {
        warn "unknown specialsv index $$sv passed to B::SPECIAL::save";
    }

    return $sym;
}

#ignore nullified cv
sub savecv { }

1;
