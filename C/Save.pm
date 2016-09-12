package B::C::Save;

use strict;

use B qw(cstring svref_2object SVf_IsCOW);
use B::C::Config;
use B::C::File qw( xpvmgsect decl init );
use B::C::Helpers qw/strlen_flags/;
use B::C::Save::Hek qw/save_hek/;
use B::C::File qw/xpvsect svsect/;

use Exporter ();
our @ISA = qw(Exporter);

our @EXPORT_OK = qw/savepvn constpv savepv inc_pv_index set_max_string_len savestash_flags savestashpv cowpv save_cow_pvs save_multicop_stash save_multicop_filegvidx multicop_filegvidx multicop_stash svop_sv_gvidx svop_sv_gv save_multisvop_sv_gv save_multisvop_sv_gvidx multigvfile_hek save_multigvfile_hek multi_cvstash save_multicv_stash/;

use constant COWPV     => 0;
use constant COWREFCNT => 1;

my %seengvfile_hek;
my %seencv_stash;
my %seencop_stash;
my %seencop_filegvidx;
my %seencow;
my %seen_svop_sv_gvidx;
my %seen_svop_sv_gv;
my %strtable;

# Two different families of save functions
#   save_* vs save*

my $pv_index = -1;

sub inc_pv_index {
    return ++$pv_index;
}

sub constpv {
    return savepv( shift, 1 );
}

sub multigvfile_hek {
    my($gvidx, $hek) = @_;

    push @{$seengvfile_hek{$hek}}, $gvidx;
    return;
}

sub multicop_filegvidx {
    my($copix, $gvidx) = @_;

    push @{$seencop_filegvidx{$gvidx}}, $copix;
    return;
}

sub multicop_stash {
    my($copix, $stash) = @_;

    push @{$seencop_stash{$stash}}, $copix;
    return;
}

sub multi_cvstash {
    my($svidx, $stash) = @_;

    die "multi_cvstash requires a index in the sv_list" if $svidx !~ m{^[0-9]+};
    push @{$seencv_stash{$stash}}, $svidx;
    return;
}

# Takes a gv index
sub svop_sv_gvidx {
    my ( $svopix, $gvidx ) = @_;

    die "svop_sv_gvidx requires a index in the gv_list" if $svopix !~ m{^[0-9]+};
    push @{ $seen_svop_sv_gvidx{$gvidx} }, $svopix;
    return;
}

# Takes a gv symbol
sub svop_sv_gv {
    my ( $svopix, $gv ) = @_;

    die "svop_sv_gv requires a GV symbol" if $gv !~ m{SV};
    push @{ $seen_svop_sv_gv{$gv} }, $svopix;
    return;
}

# %seencow Lookslike
# {
#   'STRING' => [ [ pv%d, COUNT ] ], [ [ pv%d, COUNT ], .... ]
# }
sub cowpv {
    my $pv = shift;

    $seencow{$pv} ||= [];

    if ( !$seencow{$pv}->[-1] || $seencow{$pv}->[-1]->[COWREFCNT] == 255 ) {
        my $pvsym = sprintf( "pv%d", inc_pv_index() );
        push @{ $seencow{$pv} }, [ $pvsym, 1 ];    # Always start at 1 so we have a refcount of 2 or higher to prevent free

    }

    $seencow{$pv}->[-1]->[COWREFCNT]++;

    return $seencow{$pv}->[-1]->[COWPV];
}

#   svop_list[12148].op_sv = (SV*)PL_defgv;
sub save_multisvop_sv_gv {
    foreach my $gvsym ( keys %seen_svop_sv_gv ) {
        my @svops     = @{ $seen_svop_sv_gv{$gvsym} };
        my $svopcount = scalar @svops;
        init()->add( sprintf( "SVOP_multisetgv( (const int[]){%s}, %d, %s );", join( ',', @{ $seen_svop_sv_gv{$gvsym} } ), $svopcount, $gvsym ) );
    }

}

#  svop_list[12148].op_sv = gv_list[IDX];
sub save_multisvop_sv_gvidx {
    foreach my $gvidx ( keys %seen_svop_sv_gvidx ) {
        my @svops     = @{ $seen_svop_sv_gvidx{$gvidx} };
        my $svopcount = scalar @svops;
        init()->add( sprintf( "SVOP_multisetgvidx( (const int[]){%s}, %d, %d );", join( ',', @{ $seen_svop_sv_gvidx{$gvidx} } ), $svopcount, $gvidx ) );
    }

}

sub save_multigvfile_hek {
    foreach my $hek ( keys %seengvfile_hek ) {
        my @gvs = @{$seengvfile_hek{$hek}};
        my $gvcount = scalar @gvs;
        init()->add(  sprintf( "MULTIGvFILE_HEK( %s, (const int[]){%s}, %d );", $hek, join(',', @{$seengvfile_hek{$hek}}), $gvcount)   );
    }
}

sub save_multicop_stash {
    foreach my $hv ( keys %seencop_stash ) {
        my @cops = @{$seencop_stash{$hv}};
        my $copcount = scalar @cops;
        init()->add(  sprintf( "MULTICopHV( %s, (const int[]){%s}, %d );", $hv, join(',', @{$seencop_stash{$hv}}), $copcount)   );
    }
}

sub save_multicop_filegvidx {
    foreach my $gvidx ( keys %seencop_filegvidx ) {
        my @cops = @{$seencop_filegvidx{$gvidx}};
        my $copcount = scalar @cops;
        init()->add(  sprintf( "MULTICopGVIDX( %d, (const int[]){%s}, %d );", $gvidx, join(',', @{$seencop_filegvidx{$gvidx}}), $copcount)   );
    }
}

sub save_multicv_stash {
    foreach my $hv ( keys %seencv_stash ) {
        my @cvs = @{$seencv_stash{$hv}};
        my $cvcount = scalar @cvs;
        init()->add(  sprintf( "MULTICvSTASH_set( %s, (const int[]){%s}, %d );", $hv, join(',', @{$seencv_stash{$hv}}), $cvcount)   );
    }
}


sub save_cow_pvs {
    foreach my $pv ( keys %seencow ) {
        foreach my $static_pvs ( @{ $seencow{$pv} } ) {
            my ( $pvsym, $cowrefcnt ) = @{$static_pvs};
            decl()->add( sprintf( "Static char %s[] = %s;", $pvsym, cstring( "$pv\0" . chr($cowrefcnt) ) ) );
        }
    }
}

my $max_string_len;

sub set_max_string_len {
    $max_string_len = shift;
}

sub savepv {
    my $pv    = shift;
    my $const = shift;
    my ( $cstring, $len, $utf8 ) = strlen_flags($pv);

    return $strtable{$cstring} if defined $strtable{$cstring};
    my $pvsym = sprintf( "pv%d", inc_pv_index() );
    $const = $const ? " const" : "";
    if ( defined $max_string_len && $len > $max_string_len ) {
        my $chars = join ', ', map { cchar $_ } split //, pack( "a*", $pv );
        decl()->add( sprintf( "Static%s char %s[] = { %s };", $const, $pvsym, $chars ) );
        $strtable{$cstring} = $pvsym;
    }
    else {
        if ( $cstring ne "0" ) {    # sic
            decl()->add( sprintf( "Static%s char %s[] = %s;", $const, $pvsym, $cstring ) );
            $strtable{$cstring} = $pvsym;
        }
    }
    return $pvsym;
}

sub savepvn {
    my ( $dest, $pv, $sv, $cur ) = @_;
    my @init;

    my $max_string_len = $B::C::max_string_len;    # FIXME to move here
                                                   # work with byte offsets/lengths
    $pv = pack "a*", $pv if defined $pv;
    if ( defined $max_string_len && length($pv) > $max_string_len ) {
        push @init, sprintf( "Newx(%s,%u,char);", $dest, length($pv) + 2 );
        my $offset = 0;
        while ( length $pv ) {
            my $str = substr $pv, 0, $max_string_len, '';
            push @init, sprintf( 'Copy(%s, %s+%d, %u, char);', cstring($str), $dest, $offset, length($str) );
            $offset += length $str;
        }
        push @init, sprintf( "%s[%u] = '\\0';", $dest, $offset );
        debug( pv => "Copying overlong PV %s to %s\n", cstring($pv), $dest );
    }
    else {
        # If READONLY and FAKE use newSVpvn_share instead. (test 75)
        if ( $sv and ( ( $sv->FLAGS & 0x09000000 ) == 0x09000000 ) ) {
            debug( sv => "Saving shared HEK %s to %s\n", cstring($pv), $dest );
            my $hek = save_hek($pv);
            push @init, sprintf( "%s = HEK_KEY(%s);", $dest, $hek ) unless $hek eq 'NULL';
            if ( DEBUGGING() ) {    # we have to bypass a wrong HE->HEK assert in hv.c
                push @B::C::static_free, $dest;
            }
        }
        else {
            my ( $cstr, $len, $utf8 ) = strlen_flags($pv);
            my $packed_length = length( pack "a*", $pv );
            $cur ||= ( $sv and ref($sv) and $sv->can('CUR') and ref($sv) ne 'B::GV' ) ? $sv->CUR : $packed_length;

            # We cannot COW anything except B::PV because other may store
            # things after \0.  For example
            # Boyer-Moore table is just after string and its safety-margin \0
            debug( sv => "Saving PV %s:%d to %s", $cstr, $cur, $dest );
            $cur = 0 if $cstr eq "" and $cur == 7;    # 317
            push @init, sprintf( "%s = savepvn(%s, %u);", $dest, $cstr, $cur );
        }
    }
    return @init;
}

# performance optimization:
#    limit calls to gv_stashpvn when using CopSTASHPVN_set macro

# cache to only init it once
my %stashtable;

#my $hv_index = 0; # need to use it from HV
sub savestash_flags {
    my ( $name, $cstring, $len, $flags, $disable_gvadd ) = @_;
    return $stashtable{$name} if defined $stashtable{$name};
    my $hv_index = B::C::HV::get_index();
    $flags = $flags ? "$flags|GV_ADD" : "GV_ADD" if !$disable_gvadd;    # enabled by default
    my $sym = "hv$hv_index";
    decl()->add("Static HV *$sym;");
    B::C::HV::inc_index();
    if ($name) {                                                        # since 5.18 save @ISA before calling stashpv
        my @isa = B::C::get_isa($name);
        no strict 'refs';
        if ( @isa and exists ${ $name . '::' }{ISA} ) {
            svref_2object( \@{"$name\::ISA"} )->save("$name\::ISA");
        }
    }
    my $pvsym = $len ? constpv($name) : '""';
    $stashtable{$name} = $sym;
    init()->add(
        sprintf(
            "%s = gv_stashpvn(%s, %u, %s); /* $name */",
            $sym, $pvsym, $len, $flags
        )
    );

    return $sym;
}

sub savestashpv {
    my $name = shift;
    return savestash_flags( $name, strlen_flags($name), shift );
}

1;
