package B::C::Save;

use strict;

use B qw(cstring svref_2object);
use B::C::Config;
use B::C::File qw( xpvmgsect decl init );
use B::C::Helpers qw/strlen_flags/;
use B::C::Save::Hek qw/save_hek/;

use Exporter ();
our @ISA = qw(Exporter);

our @EXPORT_OK = qw/savepvn constpv savepv inc_pv_index set_max_string_len savestash_flags savestashpv save_cow_pvs/;

my %seencow;
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

sub cowpv {
    my $pv = shift;
    $seencow{$pv}->[1]++;

    return $seencow{$pv}->[0] if $seencow{$pv}->[0];
    
    my $pvsym = sprintf( "pv%d", inc_pv_index() );
    $seencow{$pv}->[0] = $pvsym;
    return $seencow{$pv}->[0];
}

sub save_cow_pvs {
  foreach my $pv (keys %seencow) {
    my $cstring = "$pv\0" . $seencow{$pv}->[1];
    my $pvsym = $seencow{$pv}->[0];
    decl()->add( sprintf( "Static char %s[] = %s;", $pvsym, $cstring ) );
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
            my $cur ||= ( $sv and ref($sv) and $sv->can('CUR') and ref($sv) ne 'B::GV' ) ? $sv->CUR : length( pack "a*", $pv );
            if ( $cur && $dest =~ m{sv_list\[([^\]]+)\]\.} && $len < $B::C::max_string_len && ( !$seencow{$cstr} || $seencow{$cstr}->[1] < 256) ) { # 1 was B::C::IsCOW($sv) 
              my $svidx = $1;
                debug( sv => "COW: Saving PV %s:%d to %s", $cstr, $cur, $dest );
              push @init, sprintf( "%s = %s;", $dest, cowpv($pv) );
              push @init, sprintf( "SvFLAGS(&sv_list[%d]) |= SVf_IsCOW;", $svidx);
              push @init, sprintf( "SvCUR_set(&sv_list[%d],%d);", $svidx, $cur - 2 );
              push @init, sprintf( "SvLEN_set(&sv_list[%d],%d);", $svidx, $cur );
                            #push @init, sprintf( "sv_dump(&sv_list[%d]);", $svidx );
            } else {
              debug( sv => "Saving PV %s:%d to %s", $cstr, $cur, $dest );
              $cur = 0 if $cstr eq "" and $cur == 7;    # 317
              push @init, sprintf( "%s = savepvn(%s, %u);", $dest, $cstr, $cur );
            }
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