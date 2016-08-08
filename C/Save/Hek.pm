package B::C::Save::Hek;

use strict;

use B qw(cstring);
use B::C::Config;
use B::C::File qw( decl init );
use B::C::Helpers qw/strlen_flags/;

use Exporter ();
our @ISA = qw(Exporter);

our @EXPORT_OK = qw/save_hek/;

my %hektable;
my $hek_index = 0;

# Shared global string in PL_strtab.
# Mostly GvNAME and GvFILE, but also CV prototypes or bareword hash keys.
# Note: currently not used in list context
sub save_hek {
    my ( $str, $fullname, $dynamic ) = @_;    # not cstring'ed
                                              # $dynamic not yet implemented. see lexsub CvNAME in CV::save

    # $dynamic not yet implemented. see lexsub CvNAME in CV::save
    # force empty string for CV prototypes
    return "NULL" unless defined $str;
    return "NULL" if !length $str and !@_ and $fullname !~ /unopaux_item.* const/;

    # The first assigment is already refcount bumped, we have to manually
    # do it for all others
    return sprintf( "share_hek_hek(%s)", $hektable{$str} ) if defined $hektable{$str};

    my ( $cstr, $cur, $utf8 ) = strlen_flags($str);
    $cur  = -$cur if $utf8;
    $cstr = '""'  if $cstr eq "0";

    my $sym = sprintf( "hek%d", $hek_index++ );
    $hektable{$str} = $sym;
    decl()->add( sprintf( "Static HEK *%s;", $sym ) );

    debug( pv => "Saving hek %s %s cur=%d", $sym, $cstr, $cur );

    # randomized global shared hash keys:
    #   share_hek needs a non-zero hash parameter, unlike hv_store.
    #   Vulnerable to oCERT-2011-003 style DOS attacks?
    #   user-input (object fields) does not affect strtab, it is pretty safe.
    # But we need to randomize them to avoid run-time conflicts
    #   e.g. "Prototype mismatch: sub bytes::length (_) vs (_)"
    init()->add(
        sprintf(
            "%s = share_hek(%s, %d, %s);",
            $sym, $cstr, $cur, '0'
        )
    );

    return $sym;
}

1;
