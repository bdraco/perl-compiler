package B::C::Save;

use strict;

use B qw(cstring svref_2object SVf_IsCOW);
use B::C::Config;
use B::C::File qw( xpvmgsect decl init );
use B::C::Helpers qw/strlen_flags/;
use B::C::Save::Hek qw/save_hek/;
use B::C::File qw/xpvsect svsect/;

use constant SVf_IsSTATIC => 0x10000000;

use Exporter ();
our @ISA = qw(Exporter);

our @EXPORT_OK = qw/savepvn constpv savepv inc_pv_index set_max_string_len savestash_flags savestashpv save_cow_pvs/;

our $PERL_SUPPORTS_STATIC_FLAG = 1;

use constant COWPV     => 0;
use constant COWREFCNT => 1;
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

# %seencow Lookslike
# {
#   'STRING' => [ pv%d, COUNT ]
# }
sub cowpv {
    my $pv = shift;
    $seencow{$pv}->[COWREFCNT]++;

    return $seencow{$pv}->[COWPV] if $seencow{$pv}->[COWPV];

    $seencow{$pv}->[COWREFCNT]++;    # Always have a refcount of 2 or higher to prevent free
    my $pvsym = sprintf( "pv%d", inc_pv_index() );
    $seencow{$pv}->[COWPV] = $pvsym;
    return $seencow{$pv}->[COWPV];
}

sub save_cow_pvs {
    foreach my $pv ( keys %seencow ) {
        my $cstring = cstring( "$pv\0" . chr( $seencow{$pv}->[COWREFCNT] ) );
        my $pvsym   = $seencow{$pv}->[0];
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
            my $max_string_len = $B::C::max_string_len || 32768;
            my $cur ||= ( $sv and ref($sv) and $sv->can('CUR') and ref($sv) ne 'B::GV' ) ? $sv->CUR : length( pack "a*", $pv );

            # We cannot COW anything except B::PV because other may store
            # things after \0.  For example
            # Boyer-Moore table is just after string and its safety-margin \0
            if ($B::C::const_strings
                && $PERL_SUPPORTS_STATIC_FLAG
                && $cstr ne q{""}        # TODO handle empty strings
                && ref $sv eq 'B::PV'    # see above for why this can only be B::PV and not a subclass of
                && $cur
                && $len < $max_string_len
                && ( !$seencow{$cstr} || $seencow{$cstr}->[COWREFCNT] < 255 )
                && $dest =~ m{sv_list\[([^\]]+)\]\.}
              ) {
                my $svidx = $1;
                debug( sv => "COW: Saving PV %s:%d to %s", $cstr, $cur, $dest );

                my $sv_c_struct = svsect()->get($svidx);
                my( $xpv, $refcnt_c, $flags, $savesym_c ) = split(m{\s*,\s*}, $sv_c_struct);
                $flags =~ s{^0x}{};
                $flags = hex($flags);
                $flags |= SVf_IsCOW;
                $flags |= SVf_IsSTATIC;
                my $new_sv = sprintf( '%s, %s, 0x%x, %s', $xpv, $refcnt_c, $flags, cowpv($pv) );
                svsect()->update( $svidx, $new_sv );

                # Cow is "STRING\0COUNT"
                my $len = $cur + 2;
                my ($xpvidx) = $xpv =~ m{xpv_list\[([^\]]+)\]};
                my $xpv_c_struct = xpvsect()->get($xpvidx);
                my( $stash_c, $magic_c, $cur_c, $len_c ) = split(m{\s*,\s*}, $xpv_c_struct);
                my $new_xpv = sprintf( "%s, %s, %u, {%u}", $stash_c, $magic_c, $cur, $len );
                xpvsect()->update( $xpvidx, $new_xpv );
            }
            else {
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
