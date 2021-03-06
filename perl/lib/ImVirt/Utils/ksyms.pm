# ImVirt - I'm virtualized?
#
# Authors:
#   Thomas Liske <liske@ibh.de>
#
# Copyright Holder:
#   2009 - 2012 (C) IBH IT-Service GmbH [http://www.ibh.de/]
#
# License:
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this package; if not, write to the Free Software
#   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
#

package ImVirt::Utils::ksyms;

use strict;
use warnings;
use Data::Dumper;
use ImVirt::Utils::procfs;
use constant {
    KSYM_STYPE_ABSOL	=> 'A',
    KSYM_STYPE_UDATA	=> 'B',
    KSYM_STYPE_COMMON	=> 'C',
    KSYM_STYPE_IDATA	=> 'D',
    KSYM_STYPE_ISDATA	=> 'G',
    KSYM_STYPE_IREF	=> 'I',
    KSYM_STYPE_DEBUG	=> 'N',
    KSYM_STYPE_RODATA	=> 'R',
    KSYM_STYPE_USDATA	=> 'S',
    KSYM_STYPE_TEXT	=> 'T',
    KSYM_STYPE_UNDEF	=> 'U',
    KSYM_STYPE_TWEAK	=> 'V',
    KSYM_STYPE_UWEAK	=> 'W',
};

require Exporter;
our @ISA = qw(Exporter);

our @EXPORT = qw(
    ksyms_provides
    KSYM_STYPE_ABSOL
    KSYM_STYPE_UDATA
    KSYM_STYPE_COMMON
    KSYM_STYPE_IDATA
    KSYM_STYPE_ISDATA
    KSYM_STYPE_IREF
    KSYM_STYPE_DEBUG
    KSYM_STYPE_RODATA
    KSYM_STYPE_USDATA
    KSYM_STYPE_TEXT
    KSYM_STYPE_UNDEF
    KSYM_STYPE_TWEAK
    KSYM_STYPE_UWEAK
);

our $VERSION = '0.1';

my $procdir = procfs_getmp();
my %kallsyms;

open(HKAS, "$procdir/kallsyms");
while(<HKAS>) {
	chomp;
	if(/^([a-f\d]+) (\w) (\S+)\s*(\[([^\]]+)\])?/) {
	    ${$kallsyms{$3}}{'value'} = $1;
	    ${$kallsyms{$3}}{'type'} = $2;
	    ${$kallsyms{$3}}{'module'} = $5 if(defined($5));
	}
}
ImVirt::debug(__PACKAGE__, Dumper(\%kallsyms));

sub ksym_provides($$) {
    my ($type, $name) = @_;

    return exists($kallsyms{$name}) && (${$kallsyms{$name}}{'type'} eq uc($type));
}

1;
