package Slim::Utils::Errno;

# $Id$

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

=head1 NAME

Slim::Utils::Errno

=head1 DESCRIPTION

Platform correct error constants.

=head1 EXPORTS

=over 4

=item * EWOULDBLOCK

=item * EINPROGRESS

=item * EINTR

=item * ECHILD

=item * EBADF

=back

=cut

use strict;
use Exporter::Lite;

our @EXPORT = qw(EWOULDBLOCK EINPROGRESS EINTR ECHILD EBADF);

BEGIN {
        if ($^O =~ /Win32/) {
                *EINTR       = sub () { 10004 };
                *EBADF       = sub () { 10009 };
                *ECHILD      = sub () { 10010 };
                *EWOULDBLOCK = sub () { 10035 };
                *EINPROGRESS = sub () { 10036 };
        } else {
                require Errno;
                import Errno qw(EWOULDBLOCK EINPROGRESS EINTR ECHILD EBADF);
        }
}

=head1 SEE ALSO

L<Errno>

=cut

1;

__END__
