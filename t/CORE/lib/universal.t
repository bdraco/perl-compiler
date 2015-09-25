#!./perl

# Test the Internal::* functions and other tibits in universal.c

BEGIN {
    @INC = '../lib';
    require 'test.pl';
    plan( tests => 13 );
}

for my $arg ('', 'q[]', qw( 1 undef )) {
    fresh_perl_is(<<"----", <<'====', {}, "Internals::* functions check their argument under func() AND &func() [perl #77776]");
sub tryit { eval shift or warn \$@ }
tryit "&Internals::SvREADONLY($arg)";
tryit "&Internals::SvREFCNT($arg)";
tryit "&Internals::hv_clear_placeholders($arg)";
----
Usage: Internals::SvREADONLY(SCALAR[, ON]) at (eval 1) line 1.
Usage: Internals::SvREFCNT(SCALAR[, REFCOUNT]) at (eval 2) line 1.
Usage: Internals::hv_clear_placeholders(hv) at (eval 3) line 1.
====
}

# Various conundrums with SvREADONLY

$x = *foo;
Internals::SvREADONLY $x, 1;
ok Internals::SvREADONLY($x),
         'read-only glob copies are read-only acc. to Internals::';
eval { $x = [] };
like $@, qr/Modification of a read-only value attempted at/,
    'read-only glob copies';
Internals::SvREADONLY($x,0);
$x = 42;
is $x, 42, 'Internals::SvREADONLY can turn off readonliness on globs';

# Same thing with regexps
$x = ${qr//};
Internals::SvREADONLY $x, 1;
ok Internals::SvREADONLY($x),
         'read-only regexps are read-only acc. to Internals::';
eval { $x = [] };
like $@, qr/Modification of a read-only value attempted at/,
    'read-only regexps';
Internals::SvREADONLY($x,0);
$x = 42;
is $x, 42, 'Internals::SvREADONLY can turn off readonliness on regexps';

$h{a} = __PACKAGE__;
Internals::SvREADONLY $h{a}, 1;
eval { $h{a} = 3 };
like $@, qr/Modification of a read-only value attempted at/,
    'making a COW scalar into a read-only one';

$h{b} = __PACKAGE__;
ok !Internals::SvREADONLY($h{b}),
       'cows are not read-only acc. to Internals::';
Internals::SvREADONLY($h{b},0);
$h{b} =~ y/ia/ao/;
is __PACKAGE__, 'main',
  'turning off a cow’s readonliness did not affect sharers of the same PV';