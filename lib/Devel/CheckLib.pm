# $Id: CheckLib.pm,v 1.1 2007/10/18 17:41:03 drhyde Exp $

package Devel::CheckLib;

use strict;
use vars qw($VERSION @ISA @EXPORT);
$VERSION = '0.2';
use Config;

use File::Spec;
use File::Temp;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(assert_lib check_lib_or_exit);

# localising prevents the warningness leaking out of this module
local $^W = 1;    # use warnings is a 5.6-ism

=head1 NAME

Devel::CheckLib - check that a library is available

=head1 DESCRIPTION

Devel::CheckLib is a perl module that checks whether a particular C
library is available, and dies if it is not.

=head1 SYNOPSIS

    # in a Makefile.PL or Build.PL
    use lib qw(inc);
    use Devel::CheckLib;

    check_lib_or_exit( lib => 'jpeg' );
    check_lib_or_exit( lib => [ 'iconv', 'jpeg' ] );
  
    # or prompt for path to library and then do this:
    check_lib_or_exit( lib => 'jpeg', libpath => $additional_path );

=head1 HOW IT WORKS

You pass named parameters to a function
describing how to build and link to the library.  Currently the only
parameter supported is 'lib', which can be a string or an arrayref of
several libraries.  In the future, expect us to add something for
checking that header files are available as well.

It works by trying to compile this:

    int main(void) { return 0; }

and linking it to the specified libraries.  If something pops out the end
which looks executable, then the module simply returns.  If not, it dies.

=head1 FUNCTIONS

All of these take the same named parameters and are exported by default.
To avoid exporting them, C<use Devel::CheckLib ()>.

=head2 assert_lib

Takes parameters C<lib> and C<libpath>. 
The value of C<lib> must be either a string with the name of a single 
library or a reference to an array of strings of library names.  Depending
on the compiler found, library names will be fed to the compiler either as
C<-l> arguments or as C<.lib> file names.  (E.g. C<-ljpeg> or C<jpeg.lib>)

Likewise, C<libpath> must either be a string or an array of strings
representing additional paths to search for libraries.

This will die with an error message if any of the libraries listed can
not be found.  B<Note>: dying in a Makefile.PL or Build.PL may provoke
a 'FAIL' report from CPAN Testers' automated smoke testers.  Use 
C<check_lib_or_exit> instead.

=head2 check_lib_or_exit

This behaves exactly the same as C<assert_lib()> except that instead of
dieing, it warns (with exactly the same error message) and exits.
This is intended for use in Makefile.PL / Build.PL
when you might want to prompt the user for various paths and
things before checking that what they've told you is sane.

If a library isn't found, it exits with an exit value of 0 to avoid
causing a CPAN Testers 'FAIL' report.  CPAN Testers should ignore this
result -- which is what you want if an external library dependency is not
available.

=cut

sub check_lib_or_exit {
    eval 'assert_lib(@_)';
    if($@) {
        warn $@;
        exit;
    }
}

sub assert_lib {
    my %args = @_;
    my (@libs, @libpaths);
    @libs = (ref($args{lib}) ? @{$args{lib}} : $args{lib}) 
        if $args{lib};
    @libpaths = (ref($args{libpath}) ? @{$args{libpath}} : $args{libpath}) 
        if $args{libpath};
    my $cc = _findcc();
    my($ch, $cfile) = File::Temp::tempfile(
        'assertlibXXXXXXXX', SUFFIX => '.c', UNLINK => 1
    );
    print $ch "int main(void) { return 0; }\n";
    close($ch);

    my @missing;
    for my $lib ( @libs ) {
        my $exefile = File::Temp::mktemp( 'assertlibXXXXXXXX' ) . $Config{_exe};
        my @sys_cmd;
        if ( $Config{cc} eq 'cl' ) {
            require Win32;
            my @libpath = map { 
                q{/libpath:} . Win32::GetShortPathName($_)
            } @libpaths; 
            @sys_cmd = ($cc, $cfile, "${lib}.lib", "/Fe$exefile", 
                        "/link", @libpath
            );   
        }
        else {
            my @libpath = map { "-L$_" } @libpaths;
            @sys_cmd = ($cc, $cfile,  "-o", "$exefile", "-l$lib", @libpath);
        }
        warn "# @sys_cmd\n" if $args{debug};
        my $rv = $args{debug} ? system(@sys_cmd) : _quiet_system(@sys_cmd);
        push @missing, $lib if $rv != 0 || ! -x $exefile; 
        _cleanup_exe($exefile);
    } 

    unlink $cfile;
    my $miss_string = join( q{, }, map { qq{'$_'} } @missing );
    die("Can't build and link to $miss_string\n") if @missing;
}

sub _cleanup_exe {
    my ($exefile) = @_;
    my $ofile = $exefile;
    $ofile =~ s/$Config{_exe}$/$Config{_o}/;
    unlink $exefile if -f $exefile;
    unlink $ofile if -f $ofile;
    unlink "$exefile\.manifest" if -f "$exefile\.manifest";
    return
}
    
sub _findcc {
    my @paths = split(/$Config{path_sep}/, $ENV{PATH});
    return $Config{cc} if -x $Config{cc};
    foreach my $path (@paths) {
        my $compiler = File::Spec->catfile($path, $Config{cc}) . $Config{_exe};
        return $compiler if -x $compiler;
    }
    die("Couldn't find your C compiler\n");
}

# code substantially borrowed from IPC::Run3
sub _quiet_system {
    my (@cmd) = @_;

    # save handles
    local *STDOUT_SAVE;
    local *STDERR_SAVE;
    open STDOUT_SAVE, ">&STDOUT" or die "CheckLib: $! saving STDOUT";
    open STDERR_SAVE, ">&STDERR" or die "CheckLib: $! saving STDERR";
    
    # redirect to nowhere
    local *DEV_NULL;
    open DEV_NULL, ">" . File::Spec->devnull 
        or die "CheckLib: $! opening handle to null device";
    open STDOUT, ">&" . fileno DEV_NULL
        or die "CheckLib: $! redirecting STDOUT to null handle";
    open STDERR, ">&" . fileno DEV_NULL
        or die "CheckLib: $! redirecting STDERR to null handle";

    # run system command
    my $rv = system(@cmd);

    # restore handles
    open STDOUT, ">&" . fileno STDOUT_SAVE
        or die "CheckLib: $! restoring STDOUT handle";
    open STDERR, ">&" . fileno STDERR_SAVE
        or die "CheckLib: $! restoring STDERR handle";

    return $rv;
}

=head1 PLATFORMS SUPPORTED

You must have a C compiler installed.  We check for C<$Config{cc}>,
both literally as it is in Config.pm and also in the $PATH.

Probably contains unsupportable assumptions about how to invoke the
compilers and stuff.

=head1 WARNINGS, BUGS and FEEDBACK

This is a very early release intended primarily for feedback from
people who have discussed it.  The interface may change and it has
not been adequately tested.

I welcome feedback about my code, including constructive criticism.
Bug reports should be made using L<http://rt.cpan.org/> or by email.

If you are feeling particularly generous you can encourage me in my
open source endeavours by buying me something from my wishlist:
  L<http://www.cantrell.org.uk/david/wishlist/>

=head1 SEE ALSO

L<Devel::CheckOS>

=head1 AUTHORS

David Cantrell E<lt>david@cantrell.org.ukE<gt>

David Golden E<lt>dagolden@cpan.orgE<gt>

Thanks to the cpan-testers-discuss mailing list for prompting me to write it
in the first place.

=head1 COPYRIGHT and LICENCE

Copyright 2007 David Cantrell. Portions copyright 2007 David Golden.

This module is free-as-in-speech software, and may be used, distributed,
and modified under the same conditions as perl itself.

=head1 CONSPIRACY

This module is also free-as-in-mason software.

=cut

1;
