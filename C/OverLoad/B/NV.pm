package B::NV;

use strict;

use B q/SVf_IOK/;

use B::C::Config;
use B::C::File qw/xpvnvsect svsect/;
use B::C::Decimal qw/get_double_value/;
use B::C::Helpers::Symtable qw/objsym savesym/;

sub save {
    my ( $sv, $fullname ) = @_;

    my $sym = objsym($sv);
    return $sym if defined $sym;
    my $nv = get_double_value( $sv->NV );
    $nv .= '.00' if $nv =~ /^-?\d+$/;

    # IVX is invalid in B.xs and unused
    my $iv = $sv->FLAGS & SVf_IOK ? $sv->IVX : 0;

    xpvnvsect()->comment('STASH, MAGIC, cur, len, IVX, NVX');
    xpvnvsect()->add( sprintf( 'Nullhv, {0}, 0, {0}, {%ld}, {%s}', $iv, $nv ) );

    svsect()->add( sprintf( '&xpvnv_list[%d], %Lu, 0x%x , {0}', xpvnvsect()->index, $sv->REFCNT, $sv->FLAGS ) );

    svsect()->debug( $fullname, $sv );
    debug(
        sv => "Saving NV %s to xpvnv_list[%d], sv_list[%d]\n",
        $nv, xpvnvsect()->index, svsect()->index
    );
    savesym( $sv, sprintf( "&sv_list[%d]", svsect()->index ) );
}

1;
