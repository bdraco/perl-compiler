package B::LOGOP;

use strict;

use B::C::File qw/logopsect init/;
use B::C::Helpers qw/do_labels/;
use B::C::Helpers::Symtable qw/objsym savesym/;

sub save {
    my ( $op, $level ) = @_;

    my $sym = objsym($op);
    return $sym if defined $sym;

    $level ||= 0;

    logopsect()->comment_common("first, other");
    logopsect()->add( sprintf( "%s, s\\_%x, s\\_%x", $op->_save_common, ${ $op->first }, ${ $op->other } ) );
    logopsect()->debug( $op->name, $op );
    my $ix = logopsect()->index;
    init()->add( sprintf( "logop_list[%d].op_ppaddr = %s;", $ix, $op->ppaddr ) )
      unless $B::C::optimize_ppaddr;
    $sym = savesym( $op, "(OP*)&logop_list[$ix]" );
    do_labels( $op, $level + 1, 'first', 'other' );
    return $sym;
}

1;
