#!/usr/bin/perl
#line 2 "/usr/bin/par-archive"

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell
eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

package __par_pl;

# --- This script must not use any modules at compile time ---
# use strict;

#line 161

my ($par_temp, $progname, @tmpfile);
END { if ($ENV{PAR_CLEAN}) {
    require File::Temp;
    require File::Basename;
    require File::Spec;
    my $topdir = File::Basename::dirname($par_temp);
    outs(qq{Removing files in "$par_temp"});
    File::Find::finddepth(sub { ( -d ) ? rmdir : unlink }, $par_temp);
    rmdir $par_temp;
    # Don't remove topdir because this causes a race with other apps
    # that are trying to start.

    if (-d $par_temp && $^O ne 'MSWin32') {
        # Something went wrong unlinking the temporary directory.  This
        # typically happens on platforms that disallow unlinking shared
        # libraries and executables that are in use. Unlink with a background
        # shell command so the files are no longer in use by this process.
        # Don't do anything on Windows because our parent process will
        # take care of cleaning things up.

        my $tmp = new File::Temp(
            TEMPLATE => 'tmpXXXXX',
            DIR => File::Basename::dirname($topdir),
            SUFFIX => '.cmd',
            UNLINK => 0,
        );

        print $tmp "#!/bin/sh
x=1; while [ \$x -lt 10 ]; do
   rm -rf '$par_temp'
   if [ \! -d '$par_temp' ]; then
       break
   fi
   sleep 1
   x=`expr \$x + 1`
done
rm '" . $tmp->filename . "'
";
            chmod 0700,$tmp->filename;
        my $cmd = $tmp->filename . ' >/dev/null 2>&1 &';
        close $tmp;
        system($cmd);
        outs(qq(Spawned background process to perform cleanup: )
             . $tmp->filename);
    }
} }

BEGIN {
    Internals::PAR::BOOT() if defined &Internals::PAR::BOOT;

    eval {

_par_init_env();

if (exists $ENV{PAR_ARGV_0} and $ENV{PAR_ARGV_0} ) {
    @ARGV = map $ENV{"PAR_ARGV_$_"}, (1 .. $ENV{PAR_ARGC} - 1);
    $0 = $ENV{PAR_ARGV_0};
}
else {
    for (keys %ENV) {
        delete $ENV{$_} if /^PAR_ARGV_/;
    }
}

my $quiet = !$ENV{PAR_DEBUG};

# fix $progname if invoked from PATH
my %Config = (
    path_sep    => ($^O =~ /^MSWin/ ? ';' : ':'),
    _exe        => ($^O =~ /^(?:MSWin|OS2|cygwin)/ ? '.exe' : ''),
    _delim      => ($^O =~ /^MSWin|OS2/ ? '\\' : '/'),
);

_set_progname();
_set_par_temp();

# Magic string checking and extracting bundled modules {{{
my ($start_pos, $data_pos);
{
    local $SIG{__WARN__} = sub {};

    # Check file type, get start of data section {{{
    open _FH, '<', $progname or last;
    binmode(_FH);

    my $buf;
    seek _FH, -8, 2;
    read _FH, $buf, 8;
    last unless $buf eq "\nPAR.pm\n";

    seek _FH, -12, 2;
    read _FH, $buf, 4;
    seek _FH, -12 - unpack("N", $buf), 2;
    read _FH, $buf, 4;

    $data_pos = (tell _FH) - 4;
    # }}}

    # Extracting each file into memory {{{
    my %require_list;
    while ($buf eq "FILE") {
        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        my $fullname = $buf;
        outs(qq(Unpacking file "$fullname"...));
        my $crc = ( $fullname =~ s|^([a-f\d]{8})/|| ) ? $1 : undef;
        my ($basename, $ext) = ($buf =~ m|(?:.*/)?(.*)(\..*)|);

        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        if (defined($ext) and $ext !~ /\.(?:pm|pl|ix|al)$/i) {
            my ($out, $filename) = _tempfile($ext, $crc);
            if ($out) {
                binmode($out);
                print $out $buf;
                close $out;
                chmod 0755, $filename;
            }
            $PAR::Heavy::FullCache{$fullname} = $filename;
            $PAR::Heavy::FullCache{$filename} = $fullname;
        }
        elsif ( $fullname =~ m|^/?shlib/| and defined $ENV{PAR_TEMP} ) {
            # should be moved to _tempfile()
            my $filename = "$ENV{PAR_TEMP}/$basename$ext";
            outs("SHLIB: $filename\n");
            open my $out, '>', $filename or die $!;
            binmode($out);
            print $out $buf;
            close $out;
        }
        else {
            $require_list{$fullname} =
            $PAR::Heavy::ModuleCache{$fullname} = {
                buf => $buf,
                crc => $crc,
                name => $fullname,
            };
        }
        read _FH, $buf, 4;
    }
    # }}}

    local @INC = (sub {
        my ($self, $module) = @_;

        return if ref $module or !$module;

        my $filename = delete $require_list{$module} || do {
            my $key;
            foreach (keys %require_list) {
                next unless /\Q$module\E$/;
                $key = $_; last;
            }
            delete $require_list{$key} if defined($key);
        } or return;

        $INC{$module} = "/loader/$filename/$module";

        if ($ENV{PAR_CLEAN} and defined(&IO::File::new)) {
            my $fh = IO::File->new_tmpfile or die $!;
            binmode($fh);
            print $fh $filename->{buf};
            seek($fh, 0, 0);
            return $fh;
        }
        else {
            my ($out, $name) = _tempfile('.pm', $filename->{crc});
            if ($out) {
                binmode($out);
                print $out $filename->{buf};
                close $out;
            }
            open my $fh, '<', $name or die $!;
            binmode($fh);
            return $fh;
        }

        die "Bootstrapping failed: cannot find $module!\n";
    }, @INC);

    # Now load all bundled files {{{

    # initialize shared object processing
    require XSLoader;
    require PAR::Heavy;
    require Carp::Heavy;
    require Exporter::Heavy;
    PAR::Heavy::_init_dynaloader();

    # now let's try getting helper modules from within
    require IO::File;

    # load rest of the group in
    while (my $filename = (sort keys %require_list)[0]) {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        unless ($INC{$filename} or $filename =~ /BSDPAN/) {
            # require modules, do other executable files
            if ($filename =~ /\.pmc?$/i) {
                require $filename;
            }
            else {
                # Skip ActiveState's sitecustomize.pl file:
                do $filename unless $filename =~ /sitecustomize\.pl$/;
            }
        }
        delete $require_list{$filename};
    }

    # }}}

    last unless $buf eq "PK\003\004";
    $start_pos = (tell _FH) - 4;
}
# }}}

# Argument processing {{{
my @par_args;
my ($out, $bundle, $logfh, $cache_name);

delete $ENV{PAR_APP_REUSE}; # sanitize (REUSE may be a security problem)

$quiet = 0 unless $ENV{PAR_DEBUG};
# Don't swallow arguments for compiled executables without --par-options
if (!$start_pos or ($ARGV[0] eq '--par-options' && shift)) {
    my %dist_cmd = qw(
        p   blib_to_par
        i   install_par
        u   uninstall_par
        s   sign_par
        v   verify_par
    );

    # if the app is invoked as "appname --par-options --reuse PROGRAM @PROG_ARGV",
    # use the app to run the given perl code instead of anything from the
    # app itself (but still set up the normal app environment and @INC)
    if (@ARGV and $ARGV[0] eq '--reuse') {
        shift @ARGV;
        $ENV{PAR_APP_REUSE} = shift @ARGV;
    }
    else { # normal parl behaviour

        my @add_to_inc;
        while (@ARGV) {
            $ARGV[0] =~ /^-([AIMOBLbqpiusTv])(.*)/ or last;

            if ($1 eq 'I') {
                push @add_to_inc, $2;
            }
            elsif ($1 eq 'M') {
                eval "use $2";
            }
            elsif ($1 eq 'A') {
                unshift @par_args, $2;
            }
            elsif ($1 eq 'O') {
                $out = $2;
            }
            elsif ($1 eq 'b') {
                $bundle = 'site';
            }
            elsif ($1 eq 'B') {
                $bundle = 'all';
            }
            elsif ($1 eq 'q') {
                $quiet = 1;
            }
            elsif ($1 eq 'L') {
                open $logfh, ">>", $2 or die "XXX: Cannot open log: $!";
            }
            elsif ($1 eq 'T') {
                $cache_name = $2;
            }

            shift(@ARGV);

            if (my $cmd = $dist_cmd{$1}) {
                delete $ENV{'PAR_TEMP'};
                init_inc();
                require PAR::Dist;
                &{"PAR::Dist::$cmd"}() unless @ARGV;
                &{"PAR::Dist::$cmd"}($_) for @ARGV;
                exit;
            }
        }

        unshift @INC, @add_to_inc;
    }
}

# XXX -- add --par-debug support!

# }}}

# Output mode (-O) handling {{{
if ($out) {
    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require IO::File;
        require Archive::Zip;
    }

    my $par = shift(@ARGV);
    my $zip;


    if (defined $par) {
        open my $fh, '<', $par or die "Cannot find '$par': $!";
        binmode($fh);
        bless($fh, 'IO::File');

        $zip = Archive::Zip->new;
        ( $zip->readFromFileHandle($fh, $par) == Archive::Zip::AZ_OK() )
            or die "Read '$par' error: $!";
    }


    my %env = do {
        if ($zip and my $meta = $zip->contents('META.yml')) {
            $meta =~ s/.*^par:$//ms;
            $meta =~ s/^\S.*//ms;
            $meta =~ /^  ([^:]+): (.+)$/mg;
        }
    };

    # Open input and output files {{{
    local $/ = \4;

    if (defined $par) {
        open PAR, '<', $par or die "$!: $par";
        binmode(PAR);
        die "$par is not a PAR file" unless <PAR> eq "PK\003\004";
    }

    CreatePath($out) ;
    
    my $fh = IO::File->new(
        $out,
        IO::File::O_CREAT() | IO::File::O_WRONLY() | IO::File::O_TRUNC(),
        0777,
    ) or die $!;
    binmode($fh);

    $/ = (defined $data_pos) ? \$data_pos : undef;
    seek _FH, 0, 0;
    my $loader = scalar <_FH>;
    if (!$ENV{PAR_VERBATIM} and $loader =~ /^(?:#!|\@rem)/) {
        require PAR::Filter::PodStrip;
        PAR::Filter::PodStrip->new->apply(\$loader, $0)
    }
    foreach my $key (sort keys %env) {
        my $val = $env{$key} or next;
        $val = eval $val if $val =~ /^['"]/;
        my $magic = "__ENV_PAR_" . uc($key) . "__";
        my $set = "PAR_" . uc($key) . "=$val";
        $loader =~ s{$magic( +)}{
            $magic . $set . (' ' x (length($1) - length($set)))
        }eg;
    }
    $fh->print($loader);
    $/ = undef;
    # }}}

    # Write bundled modules {{{
    if ($bundle) {
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();
        init_inc();

        require_modules();

        my @inc = sort {
            length($b) <=> length($a)
        } grep {
            !/BSDPAN/
        } grep {
            ($bundle ne 'site') or
            ($_ ne $Config::Config{archlibexp} and
             $_ ne $Config::Config{privlibexp});
        } @INC;

        # File exists test added to fix RT #41790:
        # Funny, non-existing entry in _<....auto/Compress/Raw/Zlib/autosplit.ix.
        # This is a band-aid fix with no deeper grasp of the issue.
        # Somebody please go through the pain of understanding what's happening,
        # I failed. -- Steffen
        my %files;
        /^_<(.+)$/ and -e $1 and $files{$1}++ for keys %::;
        $files{$_}++ for values %INC;

        my $lib_ext = $Config::Config{lib_ext};
        my %written;

        foreach (sort keys %files) {
            my ($name, $file);

            foreach my $dir (@inc) {
                if ($name = $PAR::Heavy::FullCache{$_}) {
                    $file = $_;
                    last;
                }
                elsif (/^(\Q$dir\E\/(.*[^Cc]))\Z/i) {
                    ($file, $name) = ($1, $2);
                    last;
                }
                elsif (m!^/loader/[^/]+/(.*[^Cc])\Z!) {
                    if (my $ref = $PAR::Heavy::ModuleCache{$1}) {
                        ($file, $name) = ($ref, $1);
                        last;
                    }
                    elsif (-f "$dir/$1") {
                        ($file, $name) = ("$dir/$1", $1);
                        last;
                    }
                }
            }

            next unless defined $name and not $written{$name}++;
            next if !ref($file) and $file =~ /\.\Q$lib_ext\E$/;
            outs( join "",
                qq(Packing "), ref $file ? $file->{name} : $file,
                qq("...)
            );

            my $content;
            if (ref($file)) {
                $content = $file->{buf};
            }
            else {
                open FILE, '<', $file or die "Can't open $file: $!";
                binmode(FILE);
                $content = <FILE>;
                close FILE;

                PAR::Filter::PodStrip->new->apply(\$content, $file)
                    if !$ENV{PAR_VERBATIM} and $name =~ /\.(?:pm|ix|al)$/i;

                PAR::Filter::PatchContent->new->apply(\$content, $file, $name);
            }

            outs(qq(Written as "$name"));
            $fh->print("FILE");
            $fh->print(pack('N', length($name) + 9));
            $fh->print(sprintf(
                "%08x/%s", Archive::Zip::computeCRC32($content), $name
            ));
            $fh->print(pack('N', length($content)));
            $fh->print($content);
        }
    }
    # }}}

    # Now write out the PAR and magic strings {{{
    $zip->writeToFileHandle($fh) if $zip;

    $cache_name = substr $cache_name, 0, 40;
    if (!$cache_name and my $mtime = (stat($out))[9]) {
        my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
            || eval { require Digest::SHA1; Digest::SHA1->new }
            || eval { require Digest::MD5; Digest::MD5->new };

        # Workaround for bug in Digest::SHA 5.38 and 5.39
        my $sha_version = eval { $Digest::SHA::VERSION } || 0;
        if ($sha_version eq '5.38' or $sha_version eq '5.39') {
            $ctx->addfile($out, "b") if ($ctx);
        }
        else {
            if ($ctx and open(my $fh, "<$out")) {
                binmode($fh);
                $ctx->addfile($fh);
                close($fh);
            }
        }

        $cache_name = $ctx ? $ctx->hexdigest : $mtime;
    }
    $cache_name .= "\0" x (41 - length $cache_name);
    $cache_name .= "CACHE";
    $fh->print($cache_name);
    $fh->print(pack('N', $fh->tell - length($loader)));
    $fh->print("\nPAR.pm\n");
    $fh->close;
    chmod 0755, $out;
    # }}}

    exit;
}
# }}}

# Prepare $progname into PAR file cache {{{
{
    last unless defined $start_pos;

    _fix_progname();

    # Now load the PAR file and put it into PAR::LibCache {{{
    require PAR;
    PAR::Heavy::_init_dynaloader();


    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require File::Find;
        require Archive::Zip;
    }
    my $zip = Archive::Zip->new;
    my $fh = IO::File->new;
    $fh->fdopen(fileno(_FH), 'r') or die "$!: $@";
    $zip->readFromFileHandle($fh, $progname) == Archive::Zip::AZ_OK() or die "$!: $@";

    push @PAR::LibCache, $zip;
    $PAR::LibCache{$progname} = $zip;

    $quiet = !$ENV{PAR_DEBUG};
    outs(qq(\$ENV{PAR_TEMP} = "$ENV{PAR_TEMP}"));

    if (defined $ENV{PAR_TEMP}) { # should be set at this point!
        foreach my $member ( $zip->members ) {
            next if $member->isDirectory;
            my $member_name = $member->fileName;
            next unless $member_name =~ m{
                ^
                /?shlib/
                (?:$Config::Config{version}/)?
                (?:$Config::Config{archname}/)?
                ([^/]+)
                $
            }x;
            my $extract_name = $1;
            my $dest_name = File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
            if (-f $dest_name && -s _ == $member->uncompressedSize()) {
                outs(qq(Skipping "$member_name" since it already exists at "$dest_name"));
            } else {
                outs(qq(Extracting "$member_name" to "$dest_name"));
                $member->extractToFileNamed($dest_name);
                chmod(0555, $dest_name) if $^O eq "hpux";
            }
        }
    }
    # }}}
}
# }}}

# If there's no main.pl to run, show usage {{{
unless ($PAR::LibCache{$progname}) {
    die << "." unless @ARGV;
Usage: $0 [ -Alib.par ] [ -Idir ] [ -Mmodule ] [ src.par ] [ program.pl ]
       $0 [ -B|-b ] [-Ooutfile] src.par
.
    $ENV{PAR_PROGNAME} = $progname = $0 = shift(@ARGV);
}
# }}}

sub CreatePath {
    my ($name) = @_;
    
    require File::Basename;
    my ($basename, $path, $ext) = File::Basename::fileparse($name, ('\..*'));
    
    require File::Path;
    
    File::Path::mkpath($path) unless(-e $path); # mkpath dies with error
}

sub require_modules {
    #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';

    require lib;
    require DynaLoader;
    require integer;
    require strict;
    require warnings;
    require vars;
    require Carp;
    require Carp::Heavy;
    require Errno;
    require Exporter::Heavy;
    require Exporter;
    require Fcntl;
    require File::Temp;
    require File::Spec;
    require XSLoader;
    require Config;
    require IO::Handle;
    require IO::File;
    require Compress::Zlib;
    require Archive::Zip;
    require PAR;
    require PAR::Heavy;
    require PAR::Dist;
    require PAR::Filter::PodStrip;
    require PAR::Filter::PatchContent;
    require attributes;
    eval { require Cwd };
    eval { require Win32 };
    eval { require Scalar::Util };
    eval { require Archive::Unzip::Burst };
    eval { require Tie::Hash::NamedCapture };
    eval { require PerlIO; require PerlIO::scalar };
}

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::SetupTemp as set_par_temp_env!
sub _set_par_temp {
    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $par_temp = $1;
        return;
    }

    foreach my $path (
        (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
        qw( C:\\TEMP /tmp . )
    ) {
        next unless defined $path and -d $path and -w $path;
        my $username;
        my $pwuid;
        # does not work everywhere:
        eval {($pwuid) = getpwuid($>) if defined $>;};

        if ( defined(&Win32::LoginName) ) {
            $username = &Win32::LoginName;
        }
        elsif (defined $pwuid) {
            $username = $pwuid;
        }
        else {
            $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
        }
        $username =~ s/\W/_/g;

        my $stmpdir = "$path$Config{_delim}par-$username";
        mkdir $stmpdir, 0755;
        if (!$ENV{PAR_CLEAN} and my $mtime = (stat($progname))[9]) {
            open (my $fh, "<". $progname);
            seek $fh, -18, 2;
            sysread $fh, my $buf, 6;
            if ($buf eq "\0CACHE") {
                seek $fh, -58, 2;
                sysread $fh, $buf, 41;
                $buf =~ s/\0//g;
                $stmpdir .= "$Config{_delim}cache-" . $buf;
            }
            else {
                my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
                    || eval { require Digest::SHA1; Digest::SHA1->new }
                    || eval { require Digest::MD5; Digest::MD5->new };

                # Workaround for bug in Digest::SHA 5.38 and 5.39
                my $sha_version = eval { $Digest::SHA::VERSION } || 0;
                if ($sha_version eq '5.38' or $sha_version eq '5.39') {
                    $ctx->addfile($progname, "b") if ($ctx);
                }
                else {
                    if ($ctx and open(my $fh, "<$progname")) {
                        binmode($fh);
                        $ctx->addfile($fh);
                        close($fh);
                    }
                }

                $stmpdir .= "$Config{_delim}cache-" . ( $ctx ? $ctx->hexdigest : $mtime );
            }
            close($fh);
        }
        else {
            $ENV{PAR_CLEAN} = 1;
            $stmpdir .= "$Config{_delim}temp-$$";
        }

        $ENV{PAR_TEMP} = $stmpdir;
        mkdir $stmpdir, 0755;
        last;
    }

    $par_temp = $1 if $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}

sub _tempfile {
    my ($ext, $crc) = @_;
    my ($fh, $filename);

    $filename = "$par_temp/$crc$ext";

    if ($ENV{PAR_CLEAN}) {
        unlink $filename if -e $filename;
        push @tmpfile, $filename;
    }
    else {
        return (undef, $filename) if (-r $filename);
    }

    open $fh, '>', $filename or die $!;
    binmode($fh);
    return($fh, $filename);
}

# same code lives in PAR::SetupProgname::set_progname
sub _set_progname {
    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $progname = $1;
    }

    $progname ||= $0;

    if ($ENV{PAR_TEMP} and index($progname, $ENV{PAR_TEMP}) >= 0) {
        $progname = substr($progname, rindex($progname, $Config{_delim}) + 1);
    }

    if (!$ENV{PAR_PROGNAME} or index($progname, $Config{_delim}) >= 0) {
        if (open my $fh, '<', $progname) {
            return if -s $fh;
        }
        if (-s "$progname$Config{_exe}") {
            $progname .= $Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        $dir =~ s/\Q$Config{_delim}\E$//;
        (($progname = "$dir$Config{_delim}$progname$Config{_exe}"), last)
            if -s "$dir$Config{_delim}$progname$Config{_exe}";
        (($progname = "$dir$Config{_delim}$progname"), last)
            if -s "$dir$Config{_delim}$progname";
    }
}

sub _fix_progname {
    $0 = $progname ||= $ENV{PAR_PROGNAME};
    if (index($progname, $Config{_delim}) < 0) {
        $progname = ".$Config{_delim}$progname";
    }

    # XXX - hack to make PWD work
    my $pwd = (defined &Cwd::getcwd) ? Cwd::getcwd()
                : ((defined &Win32::GetCwd) ? Win32::GetCwd() : `pwd`);
    chomp($pwd);
    $progname =~ s/^(?=\.\.?\Q$Config{_delim}\E)/$pwd$Config{_delim}/;

    $ENV{PAR_PROGNAME} = $progname;
}

sub _par_init_env {
    if ( $ENV{PAR_INITIALIZED}++ == 1 ) {
        return;
    } else {
        $ENV{PAR_INITIALIZED} = 2;
    }

    for (qw( SPAWNED TEMP CLEAN DEBUG CACHE PROGNAME ARGC ARGV_0 ) ) {
        delete $ENV{'PAR_'.$_};
    }
    for (qw/ TMPDIR TEMP CLEAN DEBUG /) {
        $ENV{'PAR_'.$_} = $ENV{'PAR_GLOBAL_'.$_} if exists $ENV{'PAR_GLOBAL_'.$_};
    }

    my $par_clean = "__ENV_PAR_CLEAN__               ";

    if ($ENV{PAR_TEMP}) {
        delete $ENV{PAR_CLEAN};
    }
    elsif (!exists $ENV{PAR_GLOBAL_CLEAN}) {
        my $value = substr($par_clean, 12 + length("CLEAN"));
        $ENV{PAR_CLEAN} = $1 if $value =~ /^PAR_CLEAN=(\S+)/;
    }
}

sub outs {
    return if $quiet;
    if ($logfh) {
        print $logfh "@_\n";
    }
    else {
        print "@_\n";
    }
}

sub init_inc {
    require Config;
    push @INC, grep defined, map $Config::Config{$_}, qw(
        archlibexp privlibexp sitearchexp sitelibexp
        vendorarchexp vendorlibexp
    );
}

########################################################################
# The main package for script execution

package main;

require PAR;
unshift @INC, \&PAR::find_par;
PAR->import(@par_args);

die qq(par.pl: Can't open perl script "$progname": No such file or directory\n)
    unless -e $progname;

do $progname;
CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
die $@ if $@;

};

$::__ERROR = $@ if $@;
}

CORE::exit($1) if ($::__ERROR =~/^_TK_EXIT_\((\d+)\)/);
die $::__ERROR if $::__ERROR;

1;

#line 1014

__END__
FILE   21ccf883/Compress/Raw/Zlib.pm  :�#line 1 "/usr/lib/perl/5.14/Compress/Raw/Zlib.pm"

package Compress::Raw::Zlib;

require 5.004 ;
require Exporter;
use AutoLoader;
use Carp ;

#use Parse::Parameters;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, $AUTOLOAD);

$VERSION = '2.033';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
        adler32 crc32

        ZLIB_VERSION
        ZLIB_VERNUM

        DEF_WBITS
        OS_CODE

        MAX_MEM_LEVEL
        MAX_WBITS

        Z_ASCII
        Z_BEST_COMPRESSION
        Z_BEST_SPEED
        Z_BINARY
        Z_BLOCK
        Z_BUF_ERROR
        Z_DATA_ERROR
        Z_DEFAULT_COMPRESSION
        Z_DEFAULT_STRATEGY
        Z_DEFLATED
        Z_ERRNO
        Z_FILTERED
        Z_FIXED
        Z_FINISH
        Z_FULL_FLUSH
        Z_HUFFMAN_ONLY
        Z_MEM_ERROR
        Z_NEED_DICT
        Z_NO_COMPRESSION
        Z_NO_FLUSH
        Z_NULL
        Z_OK
        Z_PARTIAL_FLUSH
        Z_RLE
        Z_STREAM_END
        Z_STREAM_ERROR
        Z_SYNC_FLUSH
        Z_TREES
        Z_UNKNOWN
        Z_VERSION_ERROR

        WANT_GZIP
        WANT_GZIP_OR_ZLIB
);

use constant WANT_GZIP           => 16;
use constant WANT_GZIP_OR_ZLIB   => 32;

sub AUTOLOAD {
    my($constname);
    ($constname = $AUTOLOAD) =~ s/.*:://;
    my ($error, $val) = constant($constname);
    Carp::croak $error if $error;
    no strict 'refs';
    *{$AUTOLOAD} = sub { $val };
    goto &{$AUTOLOAD};
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;
use constant FLAG_LIMIT_OUTPUT       => 16 ;

eval {
    require XSLoader;
    XSLoader::load('Compress::Raw::Zlib', $XS_VERSION);
    1;
} 
or do {
    require DynaLoader;
    local @ISA = qw(DynaLoader);
    bootstrap Compress::Raw::Zlib $XS_VERSION ; 
};
 

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
use constant Parse_string   => 0x10;
use constant Parse_custom   => 0x12;

use constant Parse_store_ref => 0x100 ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
use constant OFF_FIRST_ONLY => 4 ;
use constant OFF_STICKY     => 5 ;



sub ParseParameters
{
    my $level = shift || 0 ; 

    my $sub = (caller($level + 1))[3] ;
    #local $Carp::CarpLevel = 1 ;
    my $p = new Compress::Raw::Zlib::Parameters() ;
    $p->parse(@_)
        or croak "$sub: $p->{Error}" ;

    return $p;
}


sub Compress::Raw::Zlib::Parameters::new
{
    my $class = shift ;

    my $obj = { Error => '',
                Got   => {},
              } ;

    #return bless $obj, ref($class) || $class || __PACKAGE__ ;
    return bless $obj, 'Compress::Raw::Zlib::Parameters' ;
}

sub Compress::Raw::Zlib::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;

    $self->{Error} = $error ;
    return $retval;
}
          
#sub getError
#{
#    my $self = shift ;
#    return $self->{Error} ;
#}
          
sub Compress::Raw::Zlib::Parameters::parse
{
    my $self = shift ;

    my $default = shift ;

    my $got = $self->{Got} ;
    my $firstTime = keys %{ $got } == 0 ;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;    
        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;
 
        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {
        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;
        
        for my $i (0.. $count / 2 - 1) {
            push @entered, $_[2* $i] ;
            push @entered, \$_[2* $i+1] ;
        }
    }


    while (my ($key, $v) = each %$default)
    {
        croak "need 4 params [@$v]"
            if @$v != 4 ;

        my ($first_only, $sticky, $type, $value) = @$v ;
        my $x ;
        $self->_checkType($key, \$value, $type, 0, \$x) 
            or return undef ;

        $key = lc $key;

        if ($firstTime || ! $sticky) {
            $got->{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
        }

        $got->{$key}[OFF_PARSED] = 0 ;
    }

    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;
 
        if ($got->{$canonkey} && ($firstTime ||
                                  ! $got->{$canonkey}[OFF_FIRST_ONLY]  ))
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;
            #$value = $$value unless $type & Parse_store_ref ;
            $value = $$value ;
            $got->{$canonkey} = [1, $type, $value, $s] ;
        }
        else
          { push (@Bad, $key) }
    }
 
    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) @Bad") ;
    }

    return 1;
}

sub Compress::Raw::Zlib::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;
    if ( $type & Parse_store_ref)
    {
        #$value = $$value
        #    if ref ${ $value } ;

        $$output = $value ;
        return 1;
    }

    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {
        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $validate && $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $validate && $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if $validate && defined $value && $value !~ /^\d*$/;
        $$output =  defined $value ? $value != 0 : 0 ;    
        return 1;
    }
    elsif ($type & Parse_string)
    {
        $$output = defined $value ? $value : "" ;    
        return 1;
    }

    $$output = $value ;
    return 1;
}



sub Compress::Raw::Zlib::Parameters::parsed
{
    my $self = shift ;
    my $name = shift ;

    return $self->{Got}{lc $name}[OFF_PARSED] ;
}

sub Compress::Raw::Zlib::Parameters::value
{
    my $self = shift ;
    my $name = shift ;

    if (@_)
    {
        $self->{Got}{lc $name}[OFF_PARSED]  = 1;
        $self->{Got}{lc $name}[OFF_DEFAULT] = $_[0] ;
        $self->{Got}{lc $name}[OFF_FIXED]   = $_[0] ;
    }

    return $self->{Got}{lc $name}[OFF_FIXED] ;
}

sub Compress::Raw::Zlib::Deflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
            {
                'AppendOutput'  => [1, 1, Parse_boolean,  0],
                'CRC32'         => [1, 1, Parse_boolean,  0],
                'ADLER32'       => [1, 1, Parse_boolean,  0],
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::Deflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _deflateInit($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $windowBits, 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                $got->value('Dictionary')) ;

}

sub Compress::Raw::Zlib::Inflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
                    {
                        'AppendOutput'  => [1, 1, Parse_boolean,  0],
                        'LimitOutput'   => [1, 1, Parse_boolean,  0],
                        'CRC32'         => [1, 1, Parse_boolean,  0],
                        'ADLER32'       => [1, 1, Parse_boolean,  0],
                        'ConsumeInput'  => [1, 1, Parse_boolean,  1],
                        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                 
                        'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                        'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::Inflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    $flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;
    $flags |= FLAG_LIMIT_OUTPUT if $got->value('LimitOutput') ;


    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _inflateInit($flags, $windowBits, $got->value('Bufsize'), 
                 $got->value('Dictionary')) ;
}

sub Compress::Raw::Zlib::InflateScan::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
                    {
                        'CRC32'         => [1, 1, Parse_boolean,  0],
                        'ADLER32'       => [1, 1, Parse_boolean,  0],
                        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                 
                        'WindowBits'    => [1, 1, Parse_signed,   -MAX_WBITS()],
                        'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::InflateScan::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    #$flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    #$flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;

    _inflateScanInit($flags, $got->value('WindowBits'), $got->value('Bufsize'), 
                 '') ;
}

sub Compress::Raw::Zlib::inflateScanStream::createDeflateStream
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
            {
                'AppendOutput'  => [1, 1, Parse_boolean,  0],
                'CRC32'         => [1, 1, Parse_boolean,  0],
                'ADLER32'       => [1, 1, Parse_boolean,  0],
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   - MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
            }, @_) ;

    croak "Compress::Raw::Zlib::InflateScan::createDeflateStream: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    $pkg->_createDeflateStream($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $got->value('WindowBits'), 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                ) ;

}

sub Compress::Raw::Zlib::inflateScanStream::inflate
{
    my $self = shift ;
    my $buffer = $_[1];
    my $eof = $_[2];

    my $status = $self->scan(@_);

    if ($status == Z_OK() && $_[2]) {
        my $byte = ' ';
        
        $status = $self->scan(\$byte, $_[1]) ;
    }
    
    return $status ;
}

sub Compress::Raw::Zlib::deflateStream::deflateParams
{
    my $self = shift ;
    my ($got) = ParseParameters(0, {
                'Level'      => [1, 1, Parse_signed,   undef],
                'Strategy'   => [1, 1, Parse_unsigned, undef],
                'Bufsize'    => [1, 1, Parse_unsigned, undef],
                }, 
                @_) ;

    croak "Compress::Raw::Zlib::deflateParams needs Level and/or Strategy"
        unless $got->parsed('Level') + $got->parsed('Strategy') +
            $got->parsed('Bufsize');

    croak "Compress::Raw::Zlib::Inflate::deflateParams: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        if $got->parsed('Bufsize') && $got->value('Bufsize') <= 1;

    my $flags = 0;
    $flags |= 1 if $got->parsed('Level') ;
    $flags |= 2 if $got->parsed('Strategy') ;
    $flags |= 4 if $got->parsed('Bufsize') ;

    $self->_deflateParams($flags, $got->value('Level'), 
                          $got->value('Strategy'), $got->value('Bufsize'));

}


# Autoload methods go after __END__, and are processed by the autosplit program.

1;
__END__


#line 1430
FILE   901dc08a/Config.pm  �#line 1 "/usr/lib/perl/5.14/Config.pm"
# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

# for a description of the variables, please have a look at the
# Glossary file, as written in the Porting folder, or use the url:
# http://perl5.git.perl.org/perl.git/blob/HEAD:/Porting/Glossary

package Config;
use strict;
use warnings;
use vars '%Config';

# Skip @Config::EXPORT because it only contains %Config, which we special
# case below as it's not a function. @Config::EXPORT won't change in the
# lifetime of Perl 5.
my %Export_Cache = (myconfig => 1, config_sh => 1, config_vars => 1,
		    config_re => 1, compile_date => 1, local_patches => 1,
		    bincompat_options => 1, non_bincompat_options => 1,
		    header_files => 1);

@Config::EXPORT = qw(%Config);
@Config::EXPORT_OK = keys %Export_Cache;

# Need to stub all the functions to make code such as print Config::config_sh
# keep working

sub bincompat_options;
sub compile_date;
sub config_re;
sub config_sh;
sub config_vars;
sub header_files;
sub local_patches;
sub myconfig;
sub non_bincompat_options;

# Define our own import method to avoid pulling in the full Exporter:
sub import {
    shift;
    @_ = @Config::EXPORT unless @_;

    my @funcs = grep $_ ne '%Config', @_;
    my $export_Config = @funcs < @_ ? 1 : 0;

    no strict 'refs';
    my $callpkg = caller(0);
    foreach my $func (@funcs) {
	die qq{"$func" is not exported by the Config module\n}
	    unless $Export_Cache{$func};
	*{$callpkg.'::'.$func} = \&{$func};
    }

    *{"$callpkg\::Config"} = \%Config if $export_Config;
    return;
}

die "Perl lib version (5.14.2) doesn't match executable '$0' version ($])"
    unless $^V;

$^V eq 5.14.2
    or die "Perl lib version (5.14.2) doesn't match executable '$0' version (" .
	sprintf("v%vd",$^V) . ")";

sub FETCH {
    my($self, $key) = @_;

    # check for cached value (which may be undef so we use exists not defined)
    return exists $self->{$key} ? $self->{$key} : $self->fetch_string($key);
}

sub TIEHASH {
    bless $_[1], $_[0];
}

sub DESTROY { }

sub AUTOLOAD {
    require 'Config_heavy.pl';
    goto \&launcher unless $Config::AUTOLOAD =~ /launcher$/;
    die "&Config::AUTOLOAD failed on $Config::AUTOLOAD";
}

# tie returns the object, so the value returned to require will be true.
tie %Config, 'Config', {
    archlibexp => '/usr/lib/perl/5.14',
    archname => 'x86_64-linux-gnu-thread-multi',
    cc => 'cc',
    d_readlink => 'define',
    d_symlink => 'define',
    dlext => 'so',
    dlsrc => 'dl_dlopen.xs',
    dont_use_nlink => undef,
    exe_ext => '',
    inc_version_list => '',
    intsize => '4',
    ldlibpthname => 'LD_LIBRARY_PATH',
    libpth => '/usr/local/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib',
    osname => 'linux',
    osvers => '3.2.0-3-amd64',
    path_sep => ':',
    privlibexp => '/usr/share/perl/5.14',
    scriptdir => '/usr/bin',
    sitearchexp => '/usr/local/lib/perl/5.14.2',
    sitelibexp => '/usr/local/share/perl/5.14.2',
    so => 'so',
    useithreads => 'define',
    usevendorprefix => 'define',
    version => '5.14.2',
};
FILE   c33fbebe/Config_git.pl  �######################################################################
# WARNING: 'lib/Config_git.pl' is generated by make_patchnum.pl
#          DO NOT EDIT DIRECTLY - edit make_patchnum.pl instead
######################################################################
$Config::Git_Data=<<'ENDOFGIT';
git_commit_id=''
git_describe=''
git_branch=''
git_uncommitted_changes=''
git_commit_id_title=''

ENDOFGIT
FILE   630f06ef/Config_heavy.pl  ��# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

package Config;
use strict;
use warnings;
use vars '%Config';

sub bincompat_options {
    return split ' ', (Internals::V())[0];
}

sub non_bincompat_options {
    return split ' ', (Internals::V())[1];
}

sub compile_date {
    return (Internals::V())[2]
}

sub local_patches {
    my (undef, undef, undef, @patches) = Internals::V();
    return @patches;
}

sub _V {
    my ($bincompat, $non_bincompat, $date, @patches) = Internals::V();

    my $opts = join ' ', sort split ' ', "$bincompat $non_bincompat";

    # wrap at 76 columns.

    $opts =~ s/(?=.{53})(.{1,53}) /$1\n                        /mg;

    print Config::myconfig();
    if ($^O eq 'VMS') {
        print "\nCharacteristics of this PERLSHR image: \n";
    } else {
        print "\nCharacteristics of this binary (from libperl): \n";
    }

    print "  Compile-time options: $opts\n";

    if (@patches) {
        print "  Locally applied patches:\n";
        print "\t$_\n" foreach @patches;
    }

    print "  Built under $^O\n";

    print "  $date\n" if defined $date;

    my @env = map { "$_=\"$ENV{$_}\"" } sort grep {/^PERL/} keys %ENV;
    push @env, "CYGWIN=\"$ENV{CYGWIN}\"" if $^O eq 'cygwin' and $ENV{CYGWIN};

    if (@env) {
        print "  \%ENV:\n";
        print "    $_\n" foreach @env;
    }
    print "  \@INC:\n";
    print "    $_\n" foreach @INC;
}

sub header_files {
    return qw(EXTERN.h INTERN.h XSUB.h av.h config.h cop.h cv.h
              dosish.h embed.h embedvar.h form.h gv.h handy.h hv.h intrpvar.h
              iperlsys.h keywords.h mg.h nostdio.h op.h opcode.h pad.h
              parser.h patchlevel.h perl.h perlio.h perliol.h perlsdio.h
              perlsfio.h perlvars.h perly.h pp.h pp_proto.h proto.h regcomp.h
              regexp.h regnodes.h scope.h sv.h thread.h time64.h unixish.h
              utf8.h util.h);
}

##
## This file was produced by running the Configure script. It holds all the
## definitions figured out by Configure. Should you modify one of these values,
## do not forget to propagate your changes by running "Configure -der". You may
## instead choose to run each of the .SH files by yourself, or "Configure -S".
##
#
## Package name      : perl5
## Source directory  : .
## Configuration time: Wed Oct 10 18:47:03 UTC 2012
## Configured by     : Debian Project
## Target system     : linux madeleine 3.2.0-3-amd64 #1 smp mon jul 23 02:45:17 utc 2012 x86_64 gnulinux 
#
#: Configure command line arguments.
#
#: Variables propagated from previous config.sh file.

our $summary = <<'!END!';
Summary of my $package (revision $revision $version_patchlevel_string) configuration:
  $git_commit_id_title $git_commit_id$git_ancestor_line
  Platform:
    osname=$osname, osvers=$osvers, archname=$archname
    uname='$myuname'
    config_args='$config_args'
    hint=$hint, useposix=$useposix, d_sigaction=$d_sigaction
    useithreads=$useithreads, usemultiplicity=$usemultiplicity
    useperlio=$useperlio, d_sfio=$d_sfio, uselargefiles=$uselargefiles, usesocks=$usesocks
    use64bitint=$use64bitint, use64bitall=$use64bitall, uselongdouble=$uselongdouble
    usemymalloc=$usemymalloc, bincompat5005=undef
  Compiler:
    cc='$cc', ccflags ='$ccflags',
    optimize='$optimize',
    cppflags='$cppflags'
    ccversion='$ccversion', gccversion='$gccversion', gccosandvers='$gccosandvers'
    intsize=$intsize, longsize=$longsize, ptrsize=$ptrsize, doublesize=$doublesize, byteorder=$byteorder
    d_longlong=$d_longlong, longlongsize=$longlongsize, d_longdbl=$d_longdbl, longdblsize=$longdblsize
    ivtype='$ivtype', ivsize=$ivsize, nvtype='$nvtype', nvsize=$nvsize, Off_t='$lseektype', lseeksize=$lseeksize
    alignbytes=$alignbytes, prototype=$prototype
  Linker and Libraries:
    ld='$ld', ldflags ='$ldflags'
    libpth=$libpth
    libs=$libs
    perllibs=$perllibs
    libc=$libc, so=$so, useshrplib=$useshrplib, libperl=$libperl
    gnulibc_version='$gnulibc_version'
  Dynamic Linking:
    dlsrc=$dlsrc, dlext=$dlext, d_dlsymun=$d_dlsymun, ccdlflags='$ccdlflags'
    cccdlflags='$cccdlflags', lddlflags='$lddlflags'

!END!
my $summary_expanded;

sub myconfig {
    return $summary_expanded if $summary_expanded;
    ($summary_expanded = $summary) =~ s{\$(\w+)}
		 { 
			my $c;
			if ($1 eq 'git_ancestor_line') {
				if ($Config::Config{git_ancestor}) {
					$c= "\n  Ancestor: $Config::Config{git_ancestor}";
				} else {
					$c= "";
				}
			} else {
                     		$c = $Config::Config{$1}; 
			}
			defined($c) ? $c : 'undef' 
		}ge;
    $summary_expanded;
}

local *_ = \my $a;
$_ = <<'!END!';
Author=''
CONFIG='true'
Date='$Date'
Header=''
Id='$Id'
Locker=''
Log='$Log'
PATCHLEVEL='14'
PERL_API_REVISION='5'
PERL_API_SUBVERSION='0'
PERL_API_VERSION='14'
PERL_CONFIG_SH='true'
PERL_PATCHLEVEL=''
PERL_REVISION='5'
PERL_SUBVERSION='2'
PERL_VERSION='14'
RCSfile='$RCSfile'
Revision='$Revision'
SUBVERSION='2'
Source=''
State=''
_a='.a'
_exe=''
_o='.o'
afs='false'
afsroot='/afs'
alignbytes='8'
ansi2knr=''
aphostname='/bin/hostname'
api_revision='5'
api_subversion='0'
api_version='14'
api_versionstring='5.14.0'
ar='ar'
archlib='/usr/lib/perl/5.14'
archlibexp='/usr/lib/perl/5.14'
archname64=''
archname='x86_64-linux-gnu-thread-multi'
archobjs=''
asctime_r_proto='REENTRANT_PROTO_B_SB'
awk='awk'
baserev='5.0'
bash=''
bin='/usr/bin'
bin_ELF='define'
binexp='/usr/bin'
bison='bison'
byacc='byacc'
byteorder='12345678'
c=''
castflags='0'
cat='cat'
cc='cc'
cccdlflags='-fPIC'
ccdlflags='-Wl,-E'
ccflags='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fstack-protector -fno-strict-aliasing -pipe -I/usr/local/include -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccflags_uselargefiles='-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccname='gcc'
ccsymbols=''
ccversion=''
cf_by='Debian Project'
cf_email='perl@packages.debian.org'
cf_time='Wed Oct 10 18:47:03 UTC 2012'
charbits='8'
charsize='1'
chgrp=''
chmod='chmod'
chown=''
clocktype='clock_t'
comm='comm'
compress=''
config_arg0='Configure'
config_arg10='-Darchlib=/usr/lib/perl/5.14'
config_arg11='-Dvendorprefix=/usr'
config_arg12='-Dvendorlib=/usr/share/perl5'
config_arg13='-Dvendorarch=/usr/lib/perl5'
config_arg14='-Dsiteprefix=/usr/local'
config_arg15='-Dsitelib=/usr/local/share/perl/5.14.2'
config_arg16='-Dsitearch=/usr/local/lib/perl/5.14.2'
config_arg17='-Dman1dir=/usr/share/man/man1'
config_arg18='-Dman3dir=/usr/share/man/man3'
config_arg19='-Dsiteman1dir=/usr/local/man/man1'
config_arg1='-Dusethreads'
config_arg20='-Dsiteman3dir=/usr/local/man/man3'
config_arg21='-Duse64bitint'
config_arg22='-Dman1ext=1'
config_arg23='-Dman3ext=3perl'
config_arg24='-Dpager=/usr/bin/sensible-pager'
config_arg25='-Uafs'
config_arg26='-Ud_csh'
config_arg27='-Ud_ualarm'
config_arg28='-Uusesfio'
config_arg29='-Uusenm'
config_arg2='-Duselargefiles'
config_arg30='-Ui_libutil'
config_arg31='-DDEBUGGING=-g'
config_arg32='-Doptimize=-O2'
config_arg33='-Duseshrplib'
config_arg34='-Dlibperl=libperl.so.5.14.2'
config_arg35='-des'
config_arg3='-Dccflags=-DDEBIAN -D_FORTIFY_SOURCE=2 -g -O2 -fstack-protector --param=ssp-buffer-size=4 -Wformat -Werror=format-security'
config_arg4='-Dldflags= -Wl,-z,relro'
config_arg5='-Dlddlflags=-shared -Wl,-z,relro'
config_arg6='-Dcccdlflags=-fPIC'
config_arg7='-Darchname=x86_64-linux-gnu'
config_arg8='-Dprefix=/usr'
config_arg9='-Dprivlib=/usr/share/perl/5.14'
config_argc='35'
config_args='-Dusethreads -Duselargefiles -Dccflags=-DDEBIAN -D_FORTIFY_SOURCE=2 -g -O2 -fstack-protector --param=ssp-buffer-size=4 -Wformat -Werror=format-security -Dldflags= -Wl,-z,relro -Dlddlflags=-shared -Wl,-z,relro -Dcccdlflags=-fPIC -Darchname=x86_64-linux-gnu -Dprefix=/usr -Dprivlib=/usr/share/perl/5.14 -Darchlib=/usr/lib/perl/5.14 -Dvendorprefix=/usr -Dvendorlib=/usr/share/perl5 -Dvendorarch=/usr/lib/perl5 -Dsiteprefix=/usr/local -Dsitelib=/usr/local/share/perl/5.14.2 -Dsitearch=/usr/local/lib/perl/5.14.2 -Dman1dir=/usr/share/man/man1 -Dman3dir=/usr/share/man/man3 -Dsiteman1dir=/usr/local/man/man1 -Dsiteman3dir=/usr/local/man/man3 -Duse64bitint -Dman1ext=1 -Dman3ext=3perl -Dpager=/usr/bin/sensible-pager -Uafs -Ud_csh -Ud_ualarm -Uusesfio -Uusenm -Ui_libutil -DDEBUGGING=-g -Doptimize=-O2 -Duseshrplib -Dlibperl=libperl.so.5.14.2 -des'
contains='grep'
cp='cp'
cpio=''
cpp='cpp'
cpp_stuff='42'
cppccsymbols=''
cppflags='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fstack-protector -fno-strict-aliasing -pipe -I/usr/local/include'
cpplast='-'
cppminus='-'
cpprun='cc -E'
cppstdin='cc -E'
cppsymbols='_FILE_OFFSET_BITS=64 _GNU_SOURCE=1 _LARGEFILE64_SOURCE=1 _LARGEFILE_SOURCE=1 _LP64=1 _POSIX_C_SOURCE=200809L _POSIX_SOURCE=1 _REENTRANT=1 _XOPEN_SOURCE=700 _XOPEN_SOURCE_EXTENDED=1 __ATOMIC_ACQUIRE=2 __ATOMIC_ACQ_REL=4 __ATOMIC_CONSUME=1 __ATOMIC_RELAXED=0 __ATOMIC_RELEASE=3 __ATOMIC_SEQ_CST=5 __BIGGEST_ALIGNMENT__=16 __BYTE_ORDER__=1234 __CHAR16_TYPE__=short\ unsigned\ int __CHAR32_TYPE__=unsigned\ int __CHAR_BIT__=8 __DBL_DECIMAL_DIG__=17 __DBL_DENORM_MIN__=((double)4.94065645841246544177e-324L) __DBL_DIG__=15 __DBL_EPSILON__=((double)2.22044604925031308085e-16L) __DBL_HAS_DENORM__=1 __DBL_HAS_INFINITY__=1 __DBL_HAS_QUIET_NAN__=1 __DBL_MANT_DIG__=53 __DBL_MAX_10_EXP__=308 __DBL_MAX_EXP__=1024 __DBL_MAX__=((double)1.79769313486231570815e+308L) __DBL_MIN_10_EXP__=(-307) __DBL_MIN_EXP__=(-1021) __DBL_MIN__=((double)2.22507385850720138309e-308L) __DEC128_EPSILON__=1E-33DL __DEC128_MANT_DIG__=34 __DEC128_MAX_EXP__=6145 __DEC128_MAX__=9.999999999999999999999999999999999E6144DL __DEC128_MIN_EXP__=(-6142) __DEC128_MIN__=1E-6143DL __DEC128_SUBNORMAL_MIN__=0.000000000000000000000000000000001E-6143DL __DEC32_EPSILON__=1E-6DF __DEC32_MANT_DIG__=7 __DEC32_MAX_EXP__=97 __DEC32_MAX__=9.999999E96DF __DEC32_MIN_EXP__=(-94) __DEC32_MIN__=1E-95DF __DEC32_SUBNORMAL_MIN__=0.000001E-95DF __DEC64_EPSILON__=1E-15DD __DEC64_MANT_DIG__=16 __DEC64_MAX_EXP__=385 __DEC64_MAX__=9.999999999999999E384DD __DEC64_MIN_EXP__=(-382) __DEC64_MIN__=1E-383DD __DEC64_SUBNORMAL_MIN__=0.000000000000001E-383DD __DECIMAL_BID_FORMAT__=1 __DECIMAL_DIG__=21 __DEC_EVAL_METHOD__=2 __ELF__=1 __FINITE_MATH_ONLY__=0 __FLOAT_WORD_ORDER__=1234 __FLT_DECIMAL_DIG__=9 __FLT_DENORM_MIN__=1.40129846432481707092e-45F __FLT_DIG__=6 __FLT_EPSILON__=1.19209289550781250000e-7F __FLT_EVAL_METHOD__=0 __FLT_HAS_DENORM__=1 __FLT_HAS_INFINITY__=1 __FLT_HAS_QUIET_NAN__=1 __FLT_MANT_DIG__=24 __FLT_MAX_10_EXP__=38 __FLT_MAX_EXP__=128 __FLT_MAX__=3.40282346638528859812e+38F __FLT_MIN_10_EXP__=(-37) __FLT_MIN_EXP__=(-125) __FLT_MIN__=1.17549435082228750797e-38F __FLT_RADIX__=2 __GCC_ATOMIC_BOOL_LOCK_FREE=2 __GCC_ATOMIC_CHAR16_T_LOCK_FREE=2 __GCC_ATOMIC_CHAR32_T_LOCK_FREE=2 __GCC_ATOMIC_CHAR_LOCK_FREE=2 __GCC_ATOMIC_INT_LOCK_FREE=2 __GCC_ATOMIC_LLONG_LOCK_FREE=2 __GCC_ATOMIC_LONG_LOCK_FREE=2 __GCC_ATOMIC_POINTER_LOCK_FREE=2 __GCC_ATOMIC_SHORT_LOCK_FREE=2 __GCC_ATOMIC_TEST_AND_SET_TRUEVAL=1 __GCC_ATOMIC_WCHAR_T_LOCK_FREE=2 __GCC_HAVE_DWARF2_CFI_ASM=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_1=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_2=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_4=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8=1 __GLIBC_MINOR__=13 __GLIBC__=2 __GNUC_GNU_INLINE__=1 __GNUC_MINOR__=7 __GNUC_PATCHLEVEL__=2 __GNUC__=4 __GNU_LIBRARY__=6 __GXX_ABI_VERSION=1002 __INT16_C(c)=c __INT16_MAX__=32767 __INT16_TYPE__=short\ int __INT32_C(c)=c __INT32_MAX__=2147483647 __INT32_TYPE__=int __INT64_C(c)=cL __INT64_MAX__=9223372036854775807L __INT64_TYPE__=long\ int __INT8_C(c)=c __INT8_MAX__=127 __INT8_TYPE__=signed\ char __INTMAX_C(c)=cL __INTMAX_MAX__=9223372036854775807L __INTMAX_TYPE__=long\ int __INTPTR_MAX__=9223372036854775807L __INTPTR_TYPE__=long\ int __INT_FAST16_MAX__=9223372036854775807L __INT_FAST16_TYPE__=long\ int __INT_FAST32_MAX__=9223372036854775807L __INT_FAST32_TYPE__=long\ int __INT_FAST64_MAX__=9223372036854775807L __INT_FAST64_TYPE__=long\ int __INT_FAST8_MAX__=127 __INT_FAST8_TYPE__=signed\ char __INT_LEAST16_MAX__=32767 __INT_LEAST16_TYPE__=short\ int __INT_LEAST32_MAX__=2147483647 __INT_LEAST32_TYPE__=int __INT_LEAST64_MAX__=9223372036854775807L __INT_LEAST64_TYPE__=long\ int __INT_LEAST8_MAX__=127 __INT_LEAST8_TYPE__=signed\ char __INT_MAX__=2147483647 __LDBL_DENORM_MIN__=3.64519953188247460253e-4951L __LDBL_DIG__=18 __LDBL_EPSILON__=1.08420217248550443401e-19L __LDBL_HAS_DENORM__=1 __LDBL_HAS_INFINITY__=1 __LDBL_HAS_QUIET_NAN__=1 __LDBL_MANT_DIG__=64 __LDBL_MAX_10_EXP__=4932 __LDBL_MAX_EXP__=16384 __LDBL_MAX__=1.18973149535723176502e+4932L __LDBL_MIN_10_EXP__=(-4931) __LDBL_MIN_EXP__=(-16381) __LDBL_MIN__=3.36210314311209350626e-4932L __LONG_LONG_MAX__=9223372036854775807LL __LONG_MAX__=9223372036854775807L __LP64__=1 __MMX__=1 __ORDER_BIG_ENDIAN__=4321 __ORDER_LITTLE_ENDIAN__=1234 __ORDER_PDP_ENDIAN__=3412 __PRAGMA_REDEFINE_EXTNAME=1 __PTRDIFF_MAX__=9223372036854775807L __PTRDIFF_TYPE__=long\ int __REGISTER_PREFIX__= __SCHAR_MAX__=127 __SHRT_MAX__=32767 __SIG_ATOMIC_MAX__=2147483647 __SIG_ATOMIC_MIN__=(-2147483647\ -\ 1) __SIG_ATOMIC_TYPE__=int __SIZEOF_DOUBLE__=8 __SIZEOF_FLOAT__=4 __SIZEOF_INT128__=16 __SIZEOF_INT__=4 __SIZEOF_LONG_DOUBLE__=16 __SIZEOF_LONG_LONG__=8 __SIZEOF_LONG__=8 __SIZEOF_POINTER__=8 __SIZEOF_PTRDIFF_T__=8 __SIZEOF_SHORT__=2 __SIZEOF_SIZE_T__=8 __SIZEOF_WCHAR_T__=4 __SIZEOF_WINT_T__=4 __SIZE_MAX__=18446744073709551615UL __SIZE_TYPE__=long\ unsigned\ int __SSE2_MATH__=1 __SSE2__=1 __SSE_MATH__=1 __SSE__=1 __STDC_HOSTED__=1 __STDC__=1 __UINT16_C(c)=c __UINT16_MAX__=65535 __UINT16_TYPE__=short\ unsigned\ int __UINT32_C(c)=cU __UINT32_MAX__=4294967295U __UINT32_TYPE__=unsigned\ int __UINT64_C(c)=cUL __UINT64_MAX__=18446744073709551615UL __UINT64_TYPE__=long\ unsigned\ int __UINT8_C(c)=c __UINT8_MAX__=255 __UINT8_TYPE__=unsigned\ char __UINTMAX_C(c)=cUL __UINTMAX_MAX__=18446744073709551615UL __UINTMAX_TYPE__=long\ unsigned\ int __UINTPTR_MAX__=18446744073709551615UL __UINTPTR_TYPE__=long\ unsigned\ int __UINT_FAST16_MAX__=18446744073709551615UL __UINT_FAST16_TYPE__=long\ unsigned\ int __UINT_FAST32_MAX__=18446744073709551615UL __UINT_FAST32_TYPE__=long\ unsigned\ int __UINT_FAST64_MAX__=18446744073709551615UL __UINT_FAST64_TYPE__=long\ unsigned\ int __UINT_FAST8_MAX__=255 __UINT_FAST8_TYPE__=unsigned\ char __UINT_LEAST16_MAX__=65535 __UINT_LEAST16_TYPE__=short\ unsigned\ int __UINT_LEAST32_MAX__=4294967295U __UINT_LEAST32_TYPE__=unsigned\ int __UINT_LEAST64_MAX__=18446744073709551615UL __UINT_LEAST64_TYPE__=long\ unsigned\ int __UINT_LEAST8_MAX__=255 __UINT_LEAST8_TYPE__=unsigned\ char __USER_LABEL_PREFIX__= __USE_BSD=1 __USE_FILE_OFFSET64=1 __USE_GNU=1 __USE_LARGEFILE64=1 __USE_LARGEFILE=1 __USE_MISC=1 __USE_POSIX199309=1 __USE_POSIX199506=1 __USE_POSIX2=1 __USE_POSIX=1 __USE_REENTRANT=1 __USE_SVID=1 __USE_UNIX98=1 __USE_XOPEN=1 __USE_XOPEN_EXTENDED=1 __VERSION__="4.7.2" __WCHAR_MAX__=2147483647 __WCHAR_MIN__=(-2147483647\ -\ 1) __WCHAR_TYPE__=int __WINT_MAX__=4294967295U __WINT_MIN__=0U __WINT_TYPE__=unsigned\ int __amd64=1 __amd64__=1 __gnu_linux__=1 __k8=1 __k8__=1 __linux=1 __linux__=1 __unix=1 __unix__=1 __x86_64=1 __x86_64__=1 linux=1 unix=1'
crypt_r_proto='REENTRANT_PROTO_B_CCS'
cryptlib=''
csh='csh'
ctermid_r_proto='0'
ctime_r_proto='REENTRANT_PROTO_B_SB'
d_Gconvert='gcvt((x),(n),(b))'
d_PRIEUldbl='define'
d_PRIFUldbl='define'
d_PRIGUldbl='define'
d_PRIXU64='define'
d_PRId64='define'
d_PRIeldbl='define'
d_PRIfldbl='define'
d_PRIgldbl='define'
d_PRIi64='define'
d_PRIo64='define'
d_PRIu64='define'
d_PRIx64='define'
d_SCNfldbl='define'
d__fwalk='undef'
d_access='define'
d_accessx='undef'
d_aintl='undef'
d_alarm='define'
d_archlib='define'
d_asctime64='undef'
d_asctime_r='define'
d_atolf='undef'
d_atoll='define'
d_attribute_deprecated='define'
d_attribute_format='define'
d_attribute_malloc='define'
d_attribute_nonnull='define'
d_attribute_noreturn='define'
d_attribute_pure='define'
d_attribute_unused='define'
d_attribute_warn_unused_result='define'
d_bcmp='define'
d_bcopy='define'
d_bsd='undef'
d_bsdgetpgrp='undef'
d_bsdsetpgrp='undef'
d_builtin_choose_expr='define'
d_builtin_expect='define'
d_bzero='define'
d_c99_variadic_macros='define'
d_casti32='undef'
d_castneg='define'
d_charvspr='undef'
d_chown='define'
d_chroot='define'
d_chsize='undef'
d_class='undef'
d_clearenv='define'
d_closedir='define'
d_cmsghdr_s='define'
d_const='define'
d_copysignl='define'
d_cplusplus='undef'
d_crypt='define'
d_crypt_r='define'
d_csh='undef'
d_ctermid='define'
d_ctermid_r='undef'
d_ctime64='undef'
d_ctime_r='define'
d_cuserid='define'
d_dbl_dig='define'
d_dbminitproto='define'
d_difftime64='undef'
d_difftime='define'
d_dir_dd_fd='undef'
d_dirfd='define'
d_dirnamlen='undef'
d_dlerror='define'
d_dlopen='define'
d_dlsymun='undef'
d_dosuid='undef'
d_drand48_r='define'
d_drand48proto='define'
d_dup2='define'
d_eaccess='define'
d_endgrent='define'
d_endgrent_r='undef'
d_endhent='define'
d_endhostent_r='undef'
d_endnent='define'
d_endnetent_r='undef'
d_endpent='define'
d_endprotoent_r='undef'
d_endpwent='define'
d_endpwent_r='undef'
d_endsent='define'
d_endservent_r='undef'
d_eofnblk='define'
d_eunice='undef'
d_faststdio='define'
d_fchdir='define'
d_fchmod='define'
d_fchown='define'
d_fcntl='define'
d_fcntl_can_lock='define'
d_fd_macros='define'
d_fd_set='define'
d_fds_bits='define'
d_fgetpos='define'
d_finite='define'
d_finitel='define'
d_flexfnam='define'
d_flock='define'
d_flockproto='define'
d_fork='define'
d_fp_class='undef'
d_fpathconf='define'
d_fpclass='undef'
d_fpclassify='undef'
d_fpclassl='undef'
d_fpos64_t='undef'
d_frexpl='define'
d_fs_data_s='undef'
d_fseeko='define'
d_fsetpos='define'
d_fstatfs='define'
d_fstatvfs='define'
d_fsync='define'
d_ftello='define'
d_ftime='undef'
d_futimes='define'
d_gdbm_ndbm_h_uses_prototypes='undef'
d_gdbmndbm_h_uses_prototypes='undef'
d_getaddrinfo='define'
d_getcwd='define'
d_getespwnam='undef'
d_getfsstat='undef'
d_getgrent='define'
d_getgrent_r='define'
d_getgrgid_r='define'
d_getgrnam_r='define'
d_getgrps='define'
d_gethbyaddr='define'
d_gethbyname='define'
d_gethent='define'
d_gethname='define'
d_gethostbyaddr_r='define'
d_gethostbyname_r='define'
d_gethostent_r='define'
d_gethostprotos='define'
d_getitimer='define'
d_getlogin='define'
d_getlogin_r='define'
d_getmnt='undef'
d_getmntent='define'
d_getnameinfo='define'
d_getnbyaddr='define'
d_getnbyname='define'
d_getnent='define'
d_getnetbyaddr_r='define'
d_getnetbyname_r='define'
d_getnetent_r='define'
d_getnetprotos='define'
d_getpagsz='define'
d_getpbyname='define'
d_getpbynumber='define'
d_getpent='define'
d_getpgid='define'
d_getpgrp2='undef'
d_getpgrp='define'
d_getppid='define'
d_getprior='define'
d_getprotobyname_r='define'
d_getprotobynumber_r='define'
d_getprotoent_r='define'
d_getprotoprotos='define'
d_getprpwnam='undef'
d_getpwent='define'
d_getpwent_r='define'
d_getpwnam_r='define'
d_getpwuid_r='define'
d_getsbyname='define'
d_getsbyport='define'
d_getsent='define'
d_getservbyname_r='define'
d_getservbyport_r='define'
d_getservent_r='define'
d_getservprotos='define'
d_getspnam='define'
d_getspnam_r='define'
d_gettimeod='define'
d_gmtime64='undef'
d_gmtime_r='define'
d_gnulibc='define'
d_grpasswd='define'
d_hasmntopt='define'
d_htonl='define'
d_ilogbl='define'
d_inc_version_list='undef'
d_index='undef'
d_inetaton='define'
d_inetntop='define'
d_inetpton='define'
d_int64_t='define'
d_isascii='define'
d_isfinite='undef'
d_isinf='define'
d_isnan='define'
d_isnanl='define'
d_killpg='define'
d_lchown='define'
d_ldbl_dig='define'
d_libm_lib_version='define'
d_link='define'
d_localtime64='undef'
d_localtime_r='define'
d_localtime_r_needs_tzset='define'
d_locconv='define'
d_lockf='define'
d_longdbl='define'
d_longlong='define'
d_lseekproto='define'
d_lstat='define'
d_madvise='define'
d_malloc_good_size='undef'
d_malloc_size='undef'
d_mblen='define'
d_mbstowcs='define'
d_mbtowc='define'
d_memchr='define'
d_memcmp='define'
d_memcpy='define'
d_memmove='define'
d_memset='define'
d_mkdir='define'
d_mkdtemp='define'
d_mkfifo='define'
d_mkstemp='define'
d_mkstemps='define'
d_mktime64='undef'
d_mktime='define'
d_mmap='define'
d_modfl='define'
d_modfl_pow32_bug='undef'
d_modflproto='define'
d_mprotect='define'
d_msg='define'
d_msg_ctrunc='define'
d_msg_dontroute='define'
d_msg_oob='define'
d_msg_peek='define'
d_msg_proxy='define'
d_msgctl='define'
d_msgget='define'
d_msghdr_s='define'
d_msgrcv='define'
d_msgsnd='define'
d_msync='define'
d_munmap='define'
d_mymalloc='undef'
d_ndbm='define'
d_ndbm_h_uses_prototypes='undef'
d_nice='define'
d_nl_langinfo='define'
d_nv_preserves_uv='undef'
d_nv_zero_is_allbits_zero='define'
d_off64_t='define'
d_old_pthread_create_joinable='undef'
d_oldpthreads='undef'
d_oldsock='undef'
d_open3='define'
d_pathconf='define'
d_pause='define'
d_perl_otherlibdirs='undef'
d_phostname='undef'
d_pipe='define'
d_poll='define'
d_portable='define'
d_prctl='define'
d_prctl_set_name='define'
d_printf_format_null='undef'
d_procselfexe='define'
d_pseudofork='undef'
d_pthread_atfork='define'
d_pthread_attr_setscope='define'
d_pthread_yield='define'
d_pwage='undef'
d_pwchange='undef'
d_pwclass='undef'
d_pwcomment='undef'
d_pwexpire='undef'
d_pwgecos='define'
d_pwpasswd='define'
d_pwquota='undef'
d_qgcvt='define'
d_quad='define'
d_random_r='define'
d_readdir64_r='define'
d_readdir='define'
d_readdir_r='define'
d_readlink='define'
d_readv='define'
d_recvmsg='define'
d_rename='define'
d_rewinddir='define'
d_rmdir='define'
d_safebcpy='undef'
d_safemcpy='undef'
d_sanemcmp='define'
d_sbrkproto='define'
d_scalbnl='define'
d_sched_yield='define'
d_scm_rights='define'
d_seekdir='define'
d_select='define'
d_sem='define'
d_semctl='define'
d_semctl_semid_ds='define'
d_semctl_semun='define'
d_semget='define'
d_semop='define'
d_sendmsg='define'
d_setegid='define'
d_seteuid='define'
d_setgrent='define'
d_setgrent_r='undef'
d_setgrps='define'
d_sethent='define'
d_sethostent_r='undef'
d_setitimer='define'
d_setlinebuf='define'
d_setlocale='define'
d_setlocale_r='undef'
d_setnent='define'
d_setnetent_r='undef'
d_setpent='define'
d_setpgid='define'
d_setpgrp2='undef'
d_setpgrp='define'
d_setprior='define'
d_setproctitle='undef'
d_setprotoent_r='undef'
d_setpwent='define'
d_setpwent_r='undef'
d_setregid='define'
d_setresgid='define'
d_setresuid='define'
d_setreuid='define'
d_setrgid='undef'
d_setruid='undef'
d_setsent='define'
d_setservent_r='undef'
d_setsid='define'
d_setvbuf='define'
d_sfio='undef'
d_shm='define'
d_shmat='define'
d_shmatprototype='define'
d_shmctl='define'
d_shmdt='define'
d_shmget='define'
d_sigaction='define'
d_signbit='define'
d_sigprocmask='define'
d_sigsetjmp='define'
d_sin6_scope_id='define'
d_sitearch='define'
d_snprintf='define'
d_sockaddr_sa_len='undef'
d_sockatmark='define'
d_sockatmarkproto='define'
d_socket='define'
d_socklen_t='define'
d_sockpair='define'
d_socks5_init='undef'
d_sprintf_returns_strlen='define'
d_sqrtl='define'
d_srand48_r='define'
d_srandom_r='define'
d_sresgproto='define'
d_sresuproto='define'
d_statblks='define'
d_statfs_f_flags='define'
d_statfs_s='define'
d_static_inline='define'
d_statvfs='define'
d_stdio_cnt_lval='undef'
d_stdio_ptr_lval='define'
d_stdio_ptr_lval_nochange_cnt='undef'
d_stdio_ptr_lval_sets_cnt='define'
d_stdio_stream_array='undef'
d_stdiobase='define'
d_stdstdio='define'
d_strchr='define'
d_strcoll='define'
d_strctcpy='define'
d_strerrm='strerror(e)'
d_strerror='define'
d_strerror_r='define'
d_strftime='define'
d_strlcat='undef'
d_strlcpy='undef'
d_strtod='define'
d_strtol='define'
d_strtold='define'
d_strtoll='define'
d_strtoq='define'
d_strtoul='define'
d_strtoull='define'
d_strtouq='define'
d_strxfrm='define'
d_suidsafe='undef'
d_symlink='define'
d_syscall='define'
d_syscallproto='define'
d_sysconf='define'
d_sysernlst=''
d_syserrlst='define'
d_system='define'
d_tcgetpgrp='define'
d_tcsetpgrp='define'
d_telldir='define'
d_telldirproto='define'
d_time='define'
d_timegm='define'
d_times='define'
d_tm_tm_gmtoff='define'
d_tm_tm_zone='define'
d_tmpnam_r='define'
d_truncate='define'
d_ttyname_r='define'
d_tzname='define'
d_u32align='define'
d_ualarm='undef'
d_umask='define'
d_uname='define'
d_union_semun='undef'
d_unordered='undef'
d_unsetenv='define'
d_usleep='define'
d_usleepproto='define'
d_ustat='define'
d_vendorarch='define'
d_vendorbin='define'
d_vendorlib='define'
d_vendorscript='define'
d_vfork='undef'
d_void_closedir='undef'
d_voidsig='define'
d_voidtty=''
d_volatile='define'
d_vprintf='define'
d_vsnprintf='define'
d_wait4='define'
d_waitpid='define'
d_wcstombs='define'
d_wctomb='define'
d_writev='define'
d_xenix='undef'
date='date'
db_hashtype='u_int32_t'
db_prefixtype='size_t'
db_version_major='5'
db_version_minor='1'
db_version_patch='29'
defvoidused='15'
direntrytype='struct dirent'
dlext='so'
dlsrc='dl_dlopen.xs'
doublesize='8'
drand01='drand48()'
drand48_r_proto='REENTRANT_PROTO_I_ST'
dtrace=''
dynamic_ext='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize XS/APItest XS/Typemap attributes mro re threads threads/shared'
eagain='EAGAIN'
ebcdic='undef'
echo='echo'
egrep='egrep'
emacs=''
endgrent_r_proto='0'
endhostent_r_proto='0'
endnetent_r_proto='0'
endprotoent_r_proto='0'
endpwent_r_proto='0'
endservent_r_proto='0'
eunicefix=':'
exe_ext=''
expr='expr'
extensions='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize XS/APItest XS/Typemap attributes mro re threads threads/shared Archive/Extract Archive/Tar Attribute/Handlers AutoLoader B/Debug B/Deparse B/Lint CGI CPAN CPAN/Meta CPAN/Meta/YAML CPANPLUS CPANPLUS/Dist/Build Devel/SelfStubber Digest Dumpvalue Env Errno ExtUtils/CBuilder ExtUtils/Command ExtUtils/Constant ExtUtils/Install ExtUtils/MakeMaker ExtUtils/Manifest ExtUtils/ParseXS File/CheckTree File/Fetch File/Path File/Temp FileCache Filter/Simple Getopt/Long HTTP/Tiny I18N/Collate I18N/LangTags IO/Compress IO/Zlib IPC/Cmd IPC/Open2 IPC/Open3 JSON/PP Locale/Codes Locale/Maketext Locale/Maketext/Simple Log/Message Log/Message/Simple Math/BigInt Math/BigRat Math/Complex Memoize Module/Build Module/CoreList Module/Load Module/Load/Conditional Module/Loaded Module/Metadata Module/Pluggable NEXT Net/Ping Object/Accessor Package/Constants Params/Check Parse/CPAN/Meta Perl/OSType PerlIO/via/QuotedPrint Pod/Escapes Pod/Html Pod/LaTeX Pod/Parser Pod/Perldoc Pod/Simple Safe SelfLoader Shell Term/ANSIColor Term/Cap Term/UI Test Test/Harness Test/Simple Text/Balanced Text/ParseWords Text/Tabs Thread/Queue Thread/Semaphore Tie/File Tie/Memoize Tie/RefHash Time/Local Version/Requirements XSLoader autodie autouse base bignum constant encoding/warnings if lib libnet parent podlators'
extern_C='extern'
extras=''
fflushNULL='define'
fflushall='undef'
find=''
firstmakefile='makefile'
flex=''
fpossize='16'
fpostype='fpos_t'
freetype='void'
from=':'
full_ar='/usr/bin/ar'
full_csh='csh'
full_sed='/bin/sed'
gccansipedantic=''
gccosandvers=''
gccversion='4.7.2'
getgrent_r_proto='REENTRANT_PROTO_I_SBWR'
getgrgid_r_proto='REENTRANT_PROTO_I_TSBWR'
getgrnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gethostbyaddr_r_proto='REENTRANT_PROTO_I_TsISBWRE'
gethostbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
gethostent_r_proto='REENTRANT_PROTO_I_SBWRE'
getlogin_r_proto='REENTRANT_PROTO_I_BW'
getnetbyaddr_r_proto='REENTRANT_PROTO_I_uISBWRE'
getnetbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
getnetent_r_proto='REENTRANT_PROTO_I_SBWRE'
getprotobyname_r_proto='REENTRANT_PROTO_I_CSBWR'
getprotobynumber_r_proto='REENTRANT_PROTO_I_ISBWR'
getprotoent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwnam_r_proto='REENTRANT_PROTO_I_CSBWR'
getpwuid_r_proto='REENTRANT_PROTO_I_TSBWR'
getservbyname_r_proto='REENTRANT_PROTO_I_CCSBWR'
getservbyport_r_proto='REENTRANT_PROTO_I_ICSBWR'
getservent_r_proto='REENTRANT_PROTO_I_SBWR'
getspnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gidformat='"u"'
gidsign='1'
gidsize='4'
gidtype='gid_t'
glibpth='/usr/shlib  /lib /usr/lib /usr/lib/386 /lib/386 /usr/ccs/lib /usr/ucblib /usr/local/lib '
gmake='gmake'
gmtime_r_proto='REENTRANT_PROTO_S_TS'
gnulibc_version='2.13'
grep='grep'
groupcat='cat /etc/group'
groupstype='gid_t'
gzip='gzip'
h_fcntl='false'
h_sysfile='true'
hint='recommended'
hostcat='cat /etc/hosts'
html1dir=' '
html1direxp=''
html3dir=' '
html3direxp=''
i16size='2'
i16type='short'
i32size='4'
i32type='int'
i64size='8'
i64type='long'
i8size='1'
i8type='signed char'
i_arpainet='define'
i_assert='define'
i_bsdioctl=''
i_crypt='define'
i_db='define'
i_dbm='define'
i_dirent='define'
i_dld='undef'
i_dlfcn='define'
i_fcntl='undef'
i_float='define'
i_fp='undef'
i_fp_class='undef'
i_gdbm='define'
i_gdbm_ndbm='define'
i_gdbmndbm='undef'
i_grp='define'
i_ieeefp='undef'
i_inttypes='define'
i_langinfo='define'
i_libutil='undef'
i_limits='define'
i_locale='define'
i_machcthr='undef'
i_malloc='define'
i_mallocmalloc='undef'
i_math='define'
i_memory='undef'
i_mntent='define'
i_ndbm='undef'
i_netdb='define'
i_neterrno='undef'
i_netinettcp='define'
i_niin='define'
i_poll='define'
i_prot='undef'
i_pthread='define'
i_pwd='define'
i_rpcsvcdbm='undef'
i_sfio='undef'
i_sgtty='undef'
i_shadow='define'
i_socks='undef'
i_stdarg='define'
i_stddef='define'
i_stdlib='define'
i_string='define'
i_sunmath='undef'
i_sysaccess='undef'
i_sysdir='define'
i_sysfile='define'
i_sysfilio='undef'
i_sysin='undef'
i_sysioctl='define'
i_syslog='define'
i_sysmman='define'
i_sysmode='undef'
i_sysmount='define'
i_sysndir='undef'
i_sysparam='define'
i_syspoll='define'
i_sysresrc='define'
i_syssecrt='undef'
i_sysselct='define'
i_syssockio='undef'
i_sysstat='define'
i_sysstatfs='define'
i_sysstatvfs='define'
i_systime='define'
i_systimek='undef'
i_systimes='define'
i_systypes='define'
i_sysuio='define'
i_sysun='define'
i_sysutsname='define'
i_sysvfs='define'
i_syswait='define'
i_termio='undef'
i_termios='define'
i_time='define'
i_unistd='define'
i_ustat='define'
i_utime='define'
i_values='define'
i_varargs='undef'
i_varhdr='stdarg.h'
i_vfork='undef'
ignore_versioned_solibs='y'
inc_version_list=''
inc_version_list_init='0'
incpath=''
inews=''
initialinstalllocation='/usr/bin'
installarchlib='/usr/lib/perl/5.14'
installbin='/usr/bin'
installhtml1dir=''
installhtml3dir=''
installman1dir='/usr/share/man/man1'
installman3dir='/usr/share/man/man3'
installprefix='/usr'
installprefixexp='/usr'
installprivlib='/usr/share/perl/5.14'
installscript='/usr/bin'
installsitearch='/usr/local/lib/perl/5.14.2'
installsitebin='/usr/local/bin'
installsitehtml1dir=''
installsitehtml3dir=''
installsitelib='/usr/local/share/perl/5.14.2'
installsiteman1dir='/usr/local/man/man1'
installsiteman3dir='/usr/local/man/man3'
installsitescript='/usr/local/bin'
installstyle='lib/perl5'
installusrbinperl='undef'
installvendorarch='/usr/lib/perl5'
installvendorbin='/usr/bin'
installvendorhtml1dir=''
installvendorhtml3dir=''
installvendorlib='/usr/share/perl5'
installvendorman1dir='/usr/share/man/man1'
installvendorman3dir='/usr/share/man/man3'
installvendorscript='/usr/bin'
intsize='4'
issymlink='test -h'
ivdformat='"ld"'
ivsize='8'
ivtype='long'
known_extensions='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize VMS/DCLsym VMS/Stdio Win32 Win32API/File Win32CORE XS/APItest XS/Typemap attributes mro re threads threads/shared '
ksh=''
ld='cc'
lddlflags='-shared -L/usr/local/lib -fstack-protector'
ldflags=' -fstack-protector -L/usr/local/lib'
ldflags_uselargefiles=''
ldlibpthname='LD_LIBRARY_PATH'
less='less'
lib_ext='.a'
libc=''
libdb_needs_pthread='N'
libperl='libperl.so.5.14.2'
libpth='/usr/local/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib'
libs='-lgdbm -lgdbm_compat -ldb -ldl -lm -lpthread -lc -lcrypt'
libsdirs=' /usr/lib/x86_64-linux-gnu'
libsfiles=' libgdbm.so libgdbm_compat.so libdb.so libdl.so libm.so libpthread.so libc.so libcrypt.so'
libsfound=' /usr/lib/x86_64-linux-gnu/libgdbm.so /usr/lib/x86_64-linux-gnu/libgdbm_compat.so /usr/lib/x86_64-linux-gnu/libdb.so /usr/lib/x86_64-linux-gnu/libdl.so /usr/lib/x86_64-linux-gnu/libm.so /usr/lib/x86_64-linux-gnu/libpthread.so /usr/lib/x86_64-linux-gnu/libc.so /usr/lib/x86_64-linux-gnu/libcrypt.so'
libspath=' /usr/local/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib'
libswanted='gdbm gdbm_compat db dl m pthread c crypt gdbm_compat'
libswanted_uselargefiles=''
line=''
lint=''
lkflags=''
ln='ln'
lns='/bin/ln -s'
localtime_r_proto='REENTRANT_PROTO_S_TS'
locincpth='/usr/local/include /opt/local/include /usr/gnu/include /opt/gnu/include /usr/GNU/include /opt/GNU/include'
loclibpth='/usr/local/lib /opt/local/lib /usr/gnu/lib /opt/gnu/lib /usr/GNU/lib /opt/GNU/lib'
longdblsize='16'
longlongsize='8'
longsize='8'
lp=''
lpr=''
ls='ls'
lseeksize='8'
lseektype='off_t'
mad='undef'
madlyh=''
madlyobj=''
madlysrc=''
mail=''
mailx=''
make='make'
make_set_make='#'
mallocobj=''
mallocsrc=''
malloctype='void *'
man1dir='/usr/share/man/man1'
man1direxp='/usr/share/man/man1'
man1ext='1p'
man3dir='/usr/share/man/man3'
man3direxp='/usr/share/man/man3'
man3ext='3pm'
mips_type=''
mistrustnm=''
mkdir='mkdir'
mmaptype='void *'
modetype='mode_t'
more='more'
multiarch='undef'
mv=''
myarchname='x86_64-linux'
mydomain=''
myhostname='localhost'
myuname='linux madeleine 3.2.0-3-amd64 #1 smp mon jul 23 02:45:17 utc 2012 x86_64 gnulinux '
n='-n'
need_va_copy='define'
netdb_hlen_type='size_t'
netdb_host_type='char *'
netdb_name_type='const char *'
netdb_net_type='in_addr_t'
nm='nm'
nm_opt=''
nm_so_opt='--dynamic'
nonxs_ext='Archive/Extract Archive/Tar Attribute/Handlers AutoLoader B/Debug B/Deparse B/Lint CGI CPAN CPAN/Meta CPAN/Meta/YAML CPANPLUS CPANPLUS/Dist/Build Devel/SelfStubber Digest Dumpvalue Env Errno ExtUtils/CBuilder ExtUtils/Command ExtUtils/Constant ExtUtils/Install ExtUtils/MakeMaker ExtUtils/Manifest ExtUtils/ParseXS File/CheckTree File/Fetch File/Path File/Temp FileCache Filter/Simple Getopt/Long HTTP/Tiny I18N/Collate I18N/LangTags IO/Compress IO/Zlib IPC/Cmd IPC/Open2 IPC/Open3 JSON/PP Locale/Codes Locale/Maketext Locale/Maketext/Simple Log/Message Log/Message/Simple Math/BigInt Math/BigRat Math/Complex Memoize Module/Build Module/CoreList Module/Load Module/Load/Conditional Module/Loaded Module/Metadata Module/Pluggable NEXT Net/Ping Object/Accessor Package/Constants Params/Check Parse/CPAN/Meta Perl/OSType PerlIO/via/QuotedPrint Pod/Escapes Pod/Html Pod/LaTeX Pod/Parser Pod/Perldoc Pod/Simple Safe SelfLoader Shell Term/ANSIColor Term/Cap Term/UI Test Test/Harness Test/Simple Text/Balanced Text/ParseWords Text/Tabs Thread/Queue Thread/Semaphore Tie/File Tie/Memoize Tie/RefHash Time/Local Version/Requirements XSLoader autodie autouse base bignum constant encoding/warnings if lib libnet parent podlators'
nroff='nroff'
nvEUformat='"E"'
nvFUformat='"F"'
nvGUformat='"G"'
nv_overflows_integers_at='256.0*256.0*256.0*256.0*256.0*256.0*2.0*2.0*2.0*2.0*2.0'
nv_preserves_uv_bits='53'
nveformat='"e"'
nvfformat='"f"'
nvgformat='"g"'
nvsize='8'
nvtype='double'
o_nonblock='O_NONBLOCK'
obj_ext='.o'
old_pthread_create_joinable=''
optimize='-O2 -g'
orderlib='false'
osname='linux'
osvers='3.2.0-3-amd64'
otherlibdirs=' '
package='perl5'
pager='/usr/bin/sensible-pager'
passcat='cat /etc/passwd'
patchlevel='14'
path_sep=':'
perl5='/usr/bin/perl'
perl='perl'
perl_patchlevel=''
perl_static_inline='static __inline__'
perladmin='root@localhost'
perllibs='-ldl -lm -lpthread -lc -lcrypt'
perlpath='/usr/bin/perl'
pg='pg'
phostname='hostname'
pidtype='pid_t'
plibpth='/lib/x86_64-linux-gnu/4.7 /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu/4.7 /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib'
pmake=''
pr=''
prefix='/usr'
prefixexp='/usr'
privlib='/usr/share/perl/5.14'
privlibexp='/usr/share/perl/5.14'
procselfexe='"/proc/self/exe"'
prototype='define'
ptrsize='8'
quadkind='2'
quadtype='long'
randbits='48'
randfunc='drand48'
random_r_proto='REENTRANT_PROTO_I_St'
randseedtype='long'
ranlib=':'
rd_nodata='-1'
readdir64_r_proto='REENTRANT_PROTO_I_TSR'
readdir_r_proto='REENTRANT_PROTO_I_TSR'
revision='5'
rm='rm'
rm_try='/bin/rm -f try try a.out .out try.[cho] try..o core core.try* try.core*'
rmail=''
run=''
runnm='false'
sGMTIME_max='67768036191676799'
sGMTIME_min='-62167219200'
sLOCALTIME_max='67768036191676799'
sLOCALTIME_min='-62167219200'
sPRIEUldbl='"LE"'
sPRIFUldbl='"LF"'
sPRIGUldbl='"LG"'
sPRIXU64='"lX"'
sPRId64='"ld"'
sPRIeldbl='"Le"'
sPRIfldbl='"Lf"'
sPRIgldbl='"Lg"'
sPRIi64='"li"'
sPRIo64='"lo"'
sPRIu64='"lu"'
sPRIx64='"lx"'
sSCNfldbl='"Lf"'
sched_yield='sched_yield()'
scriptdir='/usr/bin'
scriptdirexp='/usr/bin'
sed='sed'
seedfunc='srand48'
selectminbits='64'
selecttype='fd_set *'
sendmail=''
setgrent_r_proto='0'
sethostent_r_proto='0'
setlocale_r_proto='0'
setnetent_r_proto='0'
setprotoent_r_proto='0'
setpwent_r_proto='0'
setservent_r_proto='0'
sh='/bin/sh'
shar=''
sharpbang='#!'
shmattype='void *'
shortsize='2'
shrpenv=''
shsharp='true'
sig_count='65'
sig_name='ZERO HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM STKFLT CHLD CONT STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO PWR SYS NUM32 NUM33 RTMIN NUM35 NUM36 NUM37 NUM38 NUM39 NUM40 NUM41 NUM42 NUM43 NUM44 NUM45 NUM46 NUM47 NUM48 NUM49 NUM50 NUM51 NUM52 NUM53 NUM54 NUM55 NUM56 NUM57 NUM58 NUM59 NUM60 NUM61 NUM62 NUM63 RTMAX IOT CLD POLL UNUSED '
sig_name_init='"ZERO", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS", "NUM32", "NUM33", "RTMIN", "NUM35", "NUM36", "NUM37", "NUM38", "NUM39", "NUM40", "NUM41", "NUM42", "NUM43", "NUM44", "NUM45", "NUM46", "NUM47", "NUM48", "NUM49", "NUM50", "NUM51", "NUM52", "NUM53", "NUM54", "NUM55", "NUM56", "NUM57", "NUM58", "NUM59", "NUM60", "NUM61", "NUM62", "NUM63", "RTMAX", "IOT", "CLD", "POLL", "UNUSED", 0'
sig_num='0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 6 17 29 31 '
sig_num_init='0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 6, 17, 29, 31, 0'
sig_size='69'
signal_t='void'
sitearch='/usr/local/lib/perl/5.14.2'
sitearchexp='/usr/local/lib/perl/5.14.2'
sitebin='/usr/local/bin'
sitebinexp='/usr/local/bin'
sitehtml1dir=''
sitehtml1direxp=''
sitehtml3dir=''
sitehtml3direxp=''
sitelib='/usr/local/share/perl/5.14.2'
sitelib_stem=''
sitelibexp='/usr/local/share/perl/5.14.2'
siteman1dir='/usr/local/man/man1'
siteman1direxp='/usr/local/man/man1'
siteman3dir='/usr/local/man/man3'
siteman3direxp='/usr/local/man/man3'
siteprefix='/usr/local'
siteprefixexp='/usr/local'
sitescript='/usr/local/bin'
sitescriptexp='/usr/local/bin'
sizesize='8'
sizetype='size_t'
sleep=''
smail=''
so='so'
sockethdr=''
socketlib=''
socksizetype='socklen_t'
sort='sort'
spackage='Perl5'
spitshell='cat'
srand48_r_proto='REENTRANT_PROTO_I_LS'
srandom_r_proto='REENTRANT_PROTO_I_TS'
src='.'
ssizetype='ssize_t'
startperl='#!/usr/bin/perl'
startsh='#!/bin/sh'
static_ext=' '
stdchar='char'
stdio_base='((fp)->_IO_read_base)'
stdio_bufsiz='((fp)->_IO_read_end - (fp)->_IO_read_base)'
stdio_cnt='((fp)->_IO_read_end - (fp)->_IO_read_ptr)'
stdio_filbuf=''
stdio_ptr='((fp)->_IO_read_ptr)'
stdio_stream_array=''
strerror_r_proto='REENTRANT_PROTO_B_IBW'
strings='/usr/include/string.h'
submit=''
subversion='2'
sysman='/usr/share/man/man1'
tail=''
tar=''
targetarch=''
tbl=''
tee=''
test='test'
timeincl='/usr/include/x86_64-linux-gnu/sys/time.h /usr/include/time.h '
timetype='time_t'
tmpnam_r_proto='REENTRANT_PROTO_B_B'
to=':'
touch='touch'
tr='tr'
trnl='\n'
troff=''
ttyname_r_proto='REENTRANT_PROTO_I_IBW'
u16size='2'
u16type='unsigned short'
u32size='4'
u32type='unsigned int'
u64size='8'
u64type='unsigned long'
u8size='1'
u8type='unsigned char'
uidformat='"u"'
uidsign='1'
uidsize='4'
uidtype='uid_t'
uname='uname'
uniq='uniq'
uquadtype='unsigned long'
use5005threads='undef'
use64bitall='define'
use64bitint='define'
usecrosscompile='undef'
usedevel='undef'
usedl='define'
usedtrace='undef'
usefaststdio='undef'
useithreads='define'
uselargefiles='define'
uselongdouble='undef'
usemallocwrap='define'
usemorebits='undef'
usemultiplicity='define'
usemymalloc='n'
usenm='false'
useopcode='true'
useperlio='define'
useposix='true'
usereentrant='undef'
userelocatableinc='undef'
usesfio='false'
useshrplib='true'
usesitecustomize='undef'
usesocks='undef'
usethreads='define'
usevendorprefix='define'
usevfork='false'
usrinc='/usr/include'
uuname=''
uvXUformat='"lX"'
uvoformat='"lo"'
uvsize='8'
uvtype='unsigned long'
uvuformat='"lu"'
uvxformat='"lx"'
vaproto='define'
vendorarch='/usr/lib/perl5'
vendorarchexp='/usr/lib/perl5'
vendorbin='/usr/bin'
vendorbinexp='/usr/bin'
vendorhtml1dir=' '
vendorhtml1direxp=''
vendorhtml3dir=' '
vendorhtml3direxp=''
vendorlib='/usr/share/perl5'
vendorlib_stem=''
vendorlibexp='/usr/share/perl5'
vendorman1dir='/usr/share/man/man1'
vendorman1direxp='/usr/share/man/man1'
vendorman3dir='/usr/share/man/man3'
vendorman3direxp='/usr/share/man/man3'
vendorprefix='/usr'
vendorprefixexp='/usr'
vendorscript='/usr/bin'
vendorscriptexp='/usr/bin'
version='5.14.2'
version_patchlevel_string='version 14 subversion 2'
versiononly='undef'
vi=''
voidflags='15'
xlibpth='/usr/lib/386 /lib/386'
yacc='yacc'
yaccflags=''
zcat=''
zip='zip'
!END!

my $i = 0;
foreach my $c (8,7,6,5,4,3,2) { $i |= ord($c); $i <<= 8 }
$i |= ord(1);
our $byteorder = join('', unpack('aaaaaaaa', pack('L!', $i)));
s/(byteorder=)(['"]).*?\2/$1$2$Config::byteorder$2/m;

my $config_sh_len = length $_;

our $Config_SH_expanded = "\n$_" . << 'EOVIRTUAL';
ccflags_nolargefiles='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fstack-protector -fno-strict-aliasing -pipe -I/usr/local/include '
ldflags_nolargefiles=' -fstack-protector -L/usr/local/lib'
libs_nolargefiles='-lgdbm -lgdbm_compat -ldb -ldl -lm -lpthread -lc -lcrypt'
libswanted_nolargefiles='gdbm gdbm_compat db dl m pthread c crypt gdbm_compat'
EOVIRTUAL
eval {
	# do not have hairy conniptions if this isnt available
	require 'Config_git.pl';
	$Config_SH_expanded .= $Config::Git_Data;
	1;
} or warn "Warning: failed to load Config_git.pl, something strange about this perl...\n";

# Search for it in the big string
sub fetch_string {
    my($self, $key) = @_;

    return undef unless $Config_SH_expanded =~ /\n$key=\'(.*?)\'\n/s;
    # So we can say "if $Config{'foo'}".
    $self->{$key} = $1 eq 'undef' ? undef : $1;
}

my $prevpos = 0;

sub FIRSTKEY {
    $prevpos = 0;
    substr($Config_SH_expanded, 1, index($Config_SH_expanded, '=') - 1 );
}

sub NEXTKEY {
    my $pos = index($Config_SH_expanded, qq('\n), $prevpos) + 2;
    my $len = index($Config_SH_expanded, "=", $pos) - $pos;
    $prevpos = $pos;
    $len > 0 ? substr($Config_SH_expanded, $pos, $len) : undef;
}

sub EXISTS {
    return 1 if exists($_[0]->{$_[1]});

    return(index($Config_SH_expanded, "\n$_[1]='") != -1
          );
}

sub STORE  { die "\%Config::Config is read-only\n" }
*DELETE = *CLEAR = \*STORE; # Typeglob aliasing uses less space

sub config_sh {
    substr $Config_SH_expanded, 1, $config_sh_len;
}

sub config_re {
    my $re = shift;
    return map { chomp; $_ } grep eval{ /^(?:$re)=/ }, split /^/,
    $Config_SH_expanded;
}

sub config_vars {
    # implements -V:cfgvar option (see perlrun -V:)
    foreach (@_) {
	# find optional leading, trailing colons; and query-spec
	my ($notag,$qry,$lncont) = m/^(:)?(.*?)(:)?$/;	# flags fore and aft, 
	# map colon-flags to print decorations
	my $prfx = $notag ? '': "$qry=";		# tag-prefix for print
	my $lnend = $lncont ? ' ' : ";\n";		# line ending for print

	# all config-vars are by definition \w only, any \W means regex
	if ($qry =~ /\W/) {
	    my @matches = config_re($qry);
	    print map "$_$lnend", @matches ? @matches : "$qry: not found"		if !$notag;
	    print map { s/\w+=//; "$_$lnend" } @matches ? @matches : "$qry: not found"	if  $notag;
	} else {
	    my $v = (exists $Config::Config{$qry}) ? $Config::Config{$qry}
						   : 'UNKNOWN';
	    $v = 'undef' unless defined $v;
	    print "${prfx}'${v}'$lnend";
	}
    }
}

# Called by the real AUTOLOAD
sub launcher {
    undef &AUTOLOAD;
    goto \&$Config::AUTOLOAD;
}

1;
FILE   f53b2f60/Cwd.pm  C,#line 1 "/usr/lib/perl/5.14/Cwd.pm"
package Cwd;

use strict;
use Exporter;
use vars qw(@ISA @EXPORT @EXPORT_OK $VERSION);

$VERSION = '3.36';
my $xs_version = $VERSION;
$VERSION = eval $VERSION;

@ISA = qw/ Exporter /;
@EXPORT = qw(cwd getcwd fastcwd fastgetcwd);
push @EXPORT, qw(getdcwd) if $^O eq 'MSWin32';
@EXPORT_OK = qw(chdir abs_path fast_abs_path realpath fast_realpath);

# sys_cwd may keep the builtin command

# All the functionality of this module may provided by builtins,
# there is no sense to process the rest of the file.
# The best choice may be to have this in BEGIN, but how to return from BEGIN?

if ($^O eq 'os2') {
    local $^W = 0;

    *cwd                = defined &sys_cwd ? \&sys_cwd : \&_os2_cwd;
    *getcwd             = \&cwd;
    *fastgetcwd         = \&cwd;
    *fastcwd            = \&cwd;

    *fast_abs_path      = \&sys_abspath if defined &sys_abspath;
    *abs_path           = \&fast_abs_path;
    *realpath           = \&fast_abs_path;
    *fast_realpath      = \&fast_abs_path;

    return 1;
}

# Need to look up the feature settings on VMS.  The preferred way is to use the
# VMS::Feature module, but that may not be available to dual life modules.

my $use_vms_feature;
BEGIN {
    if ($^O eq 'VMS') {
        if (eval { local $SIG{__DIE__}; require VMS::Feature; }) {
            $use_vms_feature = 1;
        }
    }
}

# Need to look up the UNIX report mode.  This may become a dynamic mode
# in the future.
sub _vms_unix_rpt {
    my $unix_rpt;
    if ($use_vms_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    } else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i; 
    }
    return $unix_rpt;
}

# Need to look up the EFS character set mode.  This may become a dynamic
# mode in the future.
sub _vms_efs {
    my $efs;
    if ($use_vms_feature) {
        $efs = VMS::Feature::current("efs_charset");
    } else {
        my $env_efs = $ENV{'DECC$EFS_CHARSET'} || '';
        $efs = $env_efs =~ /^[ET1]/i; 
    }
    return $efs;
}

# If loading the XS stuff doesn't work, we can fall back to pure perl
eval {
  if ( $] >= 5.006 ) {
    require XSLoader;
    XSLoader::load( __PACKAGE__, $xs_version);
  } else {
    require DynaLoader;
    push @ISA, 'DynaLoader';
    __PACKAGE__->bootstrap( $xs_version );
  }
};

# Must be after the DynaLoader stuff:
$VERSION = eval $VERSION;

# Big nasty table of function aliases
my %METHOD_MAP =
  (
   VMS =>
   {
    cwd			=> '_vms_cwd',
    getcwd		=> '_vms_cwd',
    fastcwd		=> '_vms_cwd',
    fastgetcwd		=> '_vms_cwd',
    abs_path		=> '_vms_abs_path',
    fast_abs_path	=> '_vms_abs_path',
   },

   MSWin32 =>
   {
    # We assume that &_NT_cwd is defined as an XSUB or in the core.
    cwd			=> '_NT_cwd',
    getcwd		=> '_NT_cwd',
    fastcwd		=> '_NT_cwd',
    fastgetcwd		=> '_NT_cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   dos => 
   {
    cwd			=> '_dos_cwd',
    getcwd		=> '_dos_cwd',
    fastgetcwd		=> '_dos_cwd',
    fastcwd		=> '_dos_cwd',
    abs_path		=> 'fast_abs_path',
   },

   # QNX4.  QNX6 has a $os of 'nto'.
   qnx =>
   {
    cwd			=> '_qnx_cwd',
    getcwd		=> '_qnx_cwd',
    fastgetcwd		=> '_qnx_cwd',
    fastcwd		=> '_qnx_cwd',
    abs_path		=> '_qnx_abs_path',
    fast_abs_path	=> '_qnx_abs_path',
   },

   cygwin =>
   {
    getcwd		=> 'cwd',
    fastgetcwd		=> 'cwd',
    fastcwd		=> 'cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   epoc =>
   {
    cwd			=> '_epoc_cwd',
    getcwd	        => '_epoc_cwd',
    fastgetcwd		=> '_epoc_cwd',
    fastcwd		=> '_epoc_cwd',
    abs_path		=> 'fast_abs_path',
   },

   MacOS =>
   {
    getcwd		=> 'cwd',
    fastgetcwd		=> 'cwd',
    fastcwd		=> 'cwd',
    abs_path		=> 'fast_abs_path',
   },
  );

$METHOD_MAP{NT} = $METHOD_MAP{MSWin32};

# Find the pwd command in the expected locations.  We assume these
# are safe.  This prevents _backtick_pwd() consulting $ENV{PATH}
# so everything works under taint mode.
my $pwd_cmd;
foreach my $try ('/bin/pwd',
		 '/usr/bin/pwd',
		 '/QOpenSys/bin/pwd', # OS/400 PASE.
		) {

    if( -x $try ) {
        $pwd_cmd = $try;
        last;
    }
}
my $found_pwd_cmd = defined($pwd_cmd);
unless ($pwd_cmd) {
    # Isn't this wrong?  _backtick_pwd() will fail if somenone has
    # pwd in their path but it is not /bin/pwd or /usr/bin/pwd?
    # See [perl #16774]. --jhi
    $pwd_cmd = 'pwd';
}

# Lazy-load Carp
sub _carp  { require Carp; Carp::carp(@_)  }
sub _croak { require Carp; Carp::croak(@_) }

# The 'natural and safe form' for UNIX (pwd may be setuid root)
sub _backtick_pwd {
    # Localize %ENV entries in a way that won't create new hash keys
    my @localize = grep exists $ENV{$_}, qw(PATH IFS CDPATH ENV BASH_ENV);
    local @ENV{@localize};
    
    my $cwd = `$pwd_cmd`;
    # Belt-and-suspenders in case someone said "undef $/".
    local $/ = "\n";
    # `pwd` may fail e.g. if the disk is full
    chomp($cwd) if defined $cwd;
    $cwd;
}

# Since some ports may predefine cwd internally (e.g., NT)
# we take care not to override an existing definition for cwd().

unless ($METHOD_MAP{$^O}{cwd} or defined &cwd) {
    # The pwd command is not available in some chroot(2)'ed environments
    my $sep = $Config::Config{path_sep} || ':';
    my $os = $^O;  # Protect $^O from tainting

    # Try again to find a pwd, this time searching the whole PATH.
    if (defined $ENV{PATH} and $os ne 'MSWin32') {  # no pwd on Windows
	my @candidates = split($sep, $ENV{PATH});
	while (!$found_pwd_cmd and @candidates) {
	    my $candidate = shift @candidates;
	    $found_pwd_cmd = 1 if -x "$candidate/pwd";
	}
    }

    # MacOS has some special magic to make `pwd` work.
    if( $os eq 'MacOS' || $found_pwd_cmd )
    {
	*cwd = \&_backtick_pwd;
    }
    else {
	*cwd = \&getcwd;
    }
}

if ($^O eq 'cygwin') {
  # We need to make sure cwd() is called with no args, because it's
  # got an arg-less prototype and will die if args are present.
  local $^W = 0;
  my $orig_cwd = \&cwd;
  *cwd = sub { &$orig_cwd() }
}

# set a reasonable (and very safe) default for fastgetcwd, in case it
# isn't redefined later (20001212 rspier)
*fastgetcwd = \&cwd;

# A non-XS version of getcwd() - also used to bootstrap the perl build
# process, when miniperl is running and no XS loading happens.
sub _perl_getcwd
{
    abs_path('.');
}

# By John Bazik
#
# Usage: $cwd = &fastcwd;
#
# This is a faster version of getcwd.  It's also more dangerous because
# you might chdir out of a directory that you can't chdir back into.
    
sub fastcwd_ {
    my($odev, $oino, $cdev, $cino, $tdev, $tino);
    my(@path, $path);
    local(*DIR);

    my($orig_cdev, $orig_cino) = stat('.');
    ($cdev, $cino) = ($orig_cdev, $orig_cino);
    for (;;) {
	my $direntry;
	($odev, $oino) = ($cdev, $cino);
	CORE::chdir('..') || return undef;
	($cdev, $cino) = stat('.');
	last if $odev == $cdev && $oino == $cino;
	opendir(DIR, '.') || return undef;
	for (;;) {
	    $direntry = readdir(DIR);
	    last unless defined $direntry;
	    next if $direntry eq '.';
	    next if $direntry eq '..';

	    ($tdev, $tino) = lstat($direntry);
	    last unless $tdev != $odev || $tino != $oino;
	}
	closedir(DIR);
	return undef unless defined $direntry; # should never happen
	unshift(@path, $direntry);
    }
    $path = '/' . join('/', @path);
    if ($^O eq 'apollo') { $path = "/".$path; }
    # At this point $path may be tainted (if tainting) and chdir would fail.
    # Untaint it then check that we landed where we started.
    $path =~ /^(.*)\z/s		# untaint
	&& CORE::chdir($1) or return undef;
    ($cdev, $cino) = stat('.');
    die "Unstable directory path, current directory changed unexpectedly"
	if $cdev != $orig_cdev || $cino != $orig_cino;
    $path;
}
if (not defined &fastcwd) { *fastcwd = \&fastcwd_ }

# Keeps track of current working directory in PWD environment var
# Usage:
#	use Cwd 'chdir';
#	chdir $newdir;

my $chdir_init = 0;

sub chdir_init {
    if ($ENV{'PWD'} and $^O ne 'os2' and $^O ne 'dos' and $^O ne 'MSWin32') {
	my($dd,$di) = stat('.');
	my($pd,$pi) = stat($ENV{'PWD'});
	if (!defined $dd or !defined $pd or $di != $pi or $dd != $pd) {
	    $ENV{'PWD'} = cwd();
	}
    }
    else {
	my $wd = cwd();
	$wd = Win32::GetFullPathName($wd) if $^O eq 'MSWin32';
	$ENV{'PWD'} = $wd;
    }
    # Strip an automounter prefix (where /tmp_mnt/foo/bar == /foo/bar)
    if ($^O ne 'MSWin32' and $ENV{'PWD'} =~ m|(/[^/]+(/[^/]+/[^/]+))(.*)|s) {
	my($pd,$pi) = stat($2);
	my($dd,$di) = stat($1);
	if (defined $pd and defined $dd and $di == $pi and $dd == $pd) {
	    $ENV{'PWD'}="$2$3";
	}
    }
    $chdir_init = 1;
}

sub chdir {
    my $newdir = @_ ? shift : '';	# allow for no arg (chdir to HOME dir)
    $newdir =~ s|///*|/|g unless $^O eq 'MSWin32';
    chdir_init() unless $chdir_init;
    my $newpwd;
    if ($^O eq 'MSWin32') {
	# get the full path name *before* the chdir()
	$newpwd = Win32::GetFullPathName($newdir);
    }

    return 0 unless CORE::chdir $newdir;

    if ($^O eq 'VMS') {
	return $ENV{'PWD'} = $ENV{'DEFAULT'}
    }
    elsif ($^O eq 'MacOS') {
	return $ENV{'PWD'} = cwd();
    }
    elsif ($^O eq 'MSWin32') {
	$ENV{'PWD'} = $newpwd;
	return 1;
    }

    if (ref $newdir eq 'GLOB') { # in case a file/dir handle is passed in
	$ENV{'PWD'} = cwd();
    } elsif ($newdir =~ m#^/#s) {
	$ENV{'PWD'} = $newdir;
    } else {
	my @curdir = split(m#/#,$ENV{'PWD'});
	@curdir = ('') unless @curdir;
	my $component;
	foreach $component (split(m#/#, $newdir)) {
	    next if $component eq '.';
	    pop(@curdir),next if $component eq '..';
	    push(@curdir,$component);
	}
	$ENV{'PWD'} = join('/',@curdir) || '/';
    }
    1;
}

sub _perl_abs_path
{
    my $start = @_ ? shift : '.';
    my($dotdots, $cwd, @pst, @cst, $dir, @tst);

    unless (@cst = stat( $start ))
    {
	_carp("stat($start): $!");
	return '';
    }

    unless (-d _) {
        # Make sure we can be invoked on plain files, not just directories.
        # NOTE that this routine assumes that '/' is the only directory separator.
	
        my ($dir, $file) = $start =~ m{^(.*)/(.+)$}
	    or return cwd() . '/' . $start;
	
	# Can't use "-l _" here, because the previous stat was a stat(), not an lstat().
	if (-l $start) {
	    my $link_target = readlink($start);
	    die "Can't resolve link $start: $!" unless defined $link_target;
	    
	    require File::Spec;
            $link_target = $dir . '/' . $link_target
                unless File::Spec->file_name_is_absolute($link_target);
	    
	    return abs_path($link_target);
	}
	
	return $dir ? abs_path($dir) . "/$file" : "/$file";
    }

    $cwd = '';
    $dotdots = $start;
    do
    {
	$dotdots .= '/..';
	@pst = @cst;
	local *PARENT;
	unless (opendir(PARENT, $dotdots))
	{
	    # probably a permissions issue.  Try the native command.
	    return File::Spec->rel2abs( $start, _backtick_pwd() );
	}
	unless (@cst = stat($dotdots))
	{
	    _carp("stat($dotdots): $!");
	    closedir(PARENT);
	    return '';
	}
	if ($pst[0] == $cst[0] && $pst[1] == $cst[1])
	{
	    $dir = undef;
	}
	else
	{
	    do
	    {
		unless (defined ($dir = readdir(PARENT)))
	        {
		    _carp("readdir($dotdots): $!");
		    closedir(PARENT);
		    return '';
		}
		$tst[0] = $pst[0]+1 unless (@tst = lstat("$dotdots/$dir"))
	    }
	    while ($dir eq '.' || $dir eq '..' || $tst[0] != $pst[0] ||
		   $tst[1] != $pst[1]);
	}
	$cwd = (defined $dir ? "$dir" : "" ) . "/$cwd" ;
	closedir(PARENT);
    } while (defined $dir);
    chop($cwd) unless $cwd eq '/'; # drop the trailing /
    $cwd;
}

my $Curdir;
sub fast_abs_path {
    local $ENV{PWD} = $ENV{PWD} || ''; # Guard against clobberage
    my $cwd = getcwd();
    require File::Spec;
    my $path = @_ ? shift : ($Curdir ||= File::Spec->curdir);

    # Detaint else we'll explode in taint mode.  This is safe because
    # we're not doing anything dangerous with it.
    ($path) = $path =~ /(.*)/;
    ($cwd)  = $cwd  =~ /(.*)/;

    unless (-e $path) {
 	_croak("$path: No such file or directory");
    }

    unless (-d _) {
        # Make sure we can be invoked on plain files, not just directories.
	
	my ($vol, $dir, $file) = File::Spec->splitpath($path);
	return File::Spec->catfile($cwd, $path) unless length $dir;

	if (-l $path) {
	    my $link_target = readlink($path);
	    die "Can't resolve link $path: $!" unless defined $link_target;
	    
	    $link_target = File::Spec->catpath($vol, $dir, $link_target)
                unless File::Spec->file_name_is_absolute($link_target);
	    
	    return fast_abs_path($link_target);
	}
	
	return $dir eq File::Spec->rootdir
	  ? File::Spec->catpath($vol, $dir, $file)
	  : fast_abs_path(File::Spec->catpath($vol, $dir, '')) . '/' . $file;
    }

    if (!CORE::chdir($path)) {
 	_croak("Cannot chdir to $path: $!");
    }
    my $realpath = getcwd();
    if (! ((-d $cwd) && (CORE::chdir($cwd)))) {
 	_croak("Cannot chdir back to $cwd: $!");
    }
    $realpath;
}

# added function alias to follow principle of least surprise
# based on previous aliasing.  --tchrist 27-Jan-00
*fast_realpath = \&fast_abs_path;

# --- PORTING SECTION ---

# VMS: $ENV{'DEFAULT'} points to default directory at all times
# 06-Mar-1996  Charles Bailey  bailey@newman.upenn.edu
# Note: Use of Cwd::chdir() causes the logical name PWD to be defined
#   in the process logical name table as the default device and directory
#   seen by Perl. This may not be the same as the default device
#   and directory seen by DCL after Perl exits, since the effects
#   the CRTL chdir() function persist only until Perl exits.

sub _vms_cwd {
    return $ENV{'DEFAULT'};
}

sub _vms_abs_path {
    return $ENV{'DEFAULT'} unless @_;
    my $path = shift;

    my $efs = _vms_efs;
    my $unix_rpt = _vms_unix_rpt;

    if (defined &VMS::Filespec::vmsrealpath) {
        my $path_unix = 0;
        my $path_vms = 0;

        $path_unix = 1 if ($path =~ m#(?<=\^)/#);
        $path_unix = 1 if ($path =~ /^\.\.?$/);
        $path_vms = 1 if ($path =~ m#[\[<\]]#);
        $path_vms = 1 if ($path =~ /^--?$/);

        my $unix_mode = $path_unix;
        if ($efs) {
            # In case of a tie, the Unix report mode decides.
            if ($path_vms == $path_unix) {
                $unix_mode = $unix_rpt;
            } else {
                $unix_mode = 0 if $path_vms;
            }
        }

        if ($unix_mode) {
            # Unix format
            return VMS::Filespec::unixrealpath($path);
        }

	# VMS format

	my $new_path = VMS::Filespec::vmsrealpath($path);

	# Perl expects directories to be in directory format
	$new_path = VMS::Filespec::pathify($new_path) if -d $path;
	return $new_path;
    }

    # Fallback to older algorithm if correct ones are not
    # available.

    if (-l $path) {
        my $link_target = readlink($path);
        die "Can't resolve link $path: $!" unless defined $link_target;

        return _vms_abs_path($link_target);
    }

    # may need to turn foo.dir into [.foo]
    my $pathified = VMS::Filespec::pathify($path);
    $path = $pathified if defined $pathified;
	
    return VMS::Filespec::rmsexpand($path);
}

sub _os2_cwd {
    $ENV{'PWD'} = `cmd /c cd`;
    chomp $ENV{'PWD'};
    $ENV{'PWD'} =~ s:\\:/:g ;
    return $ENV{'PWD'};
}

sub _win32_cwd_simple {
    $ENV{'PWD'} = `cd`;
    chomp $ENV{'PWD'};
    $ENV{'PWD'} =~ s:\\:/:g ;
    return $ENV{'PWD'};
}

sub _win32_cwd {
    if (eval 'defined &DynaLoader::boot_DynaLoader') {
	$ENV{'PWD'} = Win32::GetCwd();
    }
    else { # miniperl
	chomp($ENV{'PWD'} = `cd`);
    }
    $ENV{'PWD'} =~ s:\\:/:g ;
    return $ENV{'PWD'};
}

*_NT_cwd = defined &Win32::GetCwd ? \&_win32_cwd : \&_win32_cwd_simple;

sub _dos_cwd {
    if (!defined &Dos::GetCwd) {
        $ENV{'PWD'} = `command /c cd`;
        chomp $ENV{'PWD'};
        $ENV{'PWD'} =~ s:\\:/:g ;
    } else {
        $ENV{'PWD'} = Dos::GetCwd();
    }
    return $ENV{'PWD'};
}

sub _qnx_cwd {
	local $ENV{PATH} = '';
	local $ENV{CDPATH} = '';
	local $ENV{ENV} = '';
    $ENV{'PWD'} = `/usr/bin/fullpath -t`;
    chomp $ENV{'PWD'};
    return $ENV{'PWD'};
}

sub _qnx_abs_path {
	local $ENV{PATH} = '';
	local $ENV{CDPATH} = '';
	local $ENV{ENV} = '';
    my $path = @_ ? shift : '.';
    local *REALPATH;

    defined( open(REALPATH, '-|') || exec '/usr/bin/fullpath', '-t', $path ) or
      die "Can't open /usr/bin/fullpath: $!";
    my $realpath = <REALPATH>;
    close REALPATH;
    chomp $realpath;
    return $realpath;
}

sub _epoc_cwd {
    $ENV{'PWD'} = EPOC::getcwd();
    return $ENV{'PWD'};
}

# Now that all the base-level functions are set up, alias the
# user-level functions to the right places

if (exists $METHOD_MAP{$^O}) {
  my $map = $METHOD_MAP{$^O};
  foreach my $name (keys %$map) {
    local $^W = 0;  # assignments trigger 'subroutine redefined' warning
    no strict 'refs';
    *{$name} = \&{$map->{$name}};
  }
}

# In case the XS version doesn't load.
*abs_path = \&_perl_abs_path unless defined &abs_path;
*getcwd = \&_perl_getcwd unless defined &getcwd;

# added function alias for those of us more
# used to the libc function.  --tchrist 27-Jan-00
*realpath = \&abs_path;

1;
FILE   559de557/Digest/SHA.pm  �#line 1 "/usr/lib/perl/5.14/Digest/SHA.pm"
package Digest::SHA;

require 5.003000;

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
use Fcntl;
use integer;

$VERSION = '5.61';

require Exporter;
require DynaLoader;
@ISA = qw(Exporter DynaLoader);
@EXPORT_OK = qw(
	hmac_sha1	hmac_sha1_base64	hmac_sha1_hex
	hmac_sha224	hmac_sha224_base64	hmac_sha224_hex
	hmac_sha256	hmac_sha256_base64	hmac_sha256_hex
	hmac_sha384	hmac_sha384_base64	hmac_sha384_hex
	hmac_sha512	hmac_sha512_base64	hmac_sha512_hex
	hmac_sha512224	hmac_sha512224_base64	hmac_sha512224_hex
	hmac_sha512256	hmac_sha512256_base64	hmac_sha512256_hex
	sha1		sha1_base64		sha1_hex
	sha224		sha224_base64		sha224_hex
	sha256		sha256_base64		sha256_hex
	sha384		sha384_base64		sha384_hex
	sha512		sha512_base64		sha512_hex
	sha512224	sha512224_base64	sha512224_hex
	sha512256	sha512256_base64	sha512256_hex);

# If possible, inherit from Digest::base (which depends on MIME::Base64)

*addfile = \&Addfile;

eval {
	require MIME::Base64;
	require Digest::base;
	push(@ISA, 'Digest::base');
};
if ($@) {
	*hexdigest = \&Hexdigest;
	*b64digest = \&B64digest;
}

# The following routines aren't time-critical, so they can be left in Perl

sub new {
	my($class, $alg) = @_;
	$alg =~ s/\D+//g if defined $alg;
	if (ref($class)) {	# instance method
		unless (defined($alg) && ($alg != $class->algorithm)) {
			sharewind($$class);
			return($class);
		}
		shaclose($$class) if $$class;
		$$class = shaopen($alg) || return;
		return($class);
	}
	$alg = 1 unless defined $alg;
	my $state = shaopen($alg) || return;
	my $self = \$state;
	bless($self, $class);
	return($self);
}

sub DESTROY {
	my $self = shift;
	shaclose($$self) if $$self;
}

sub clone {
	my $self = shift;
	my $state = shadup($$self) || return;
	my $copy = \$state;
	bless($copy, ref($self));
	return($copy);
}

*reset = \&new;

sub add_bits {
	my($self, $data, $nbits) = @_;
	unless (defined $nbits) {
		$nbits = length($data);
		$data = pack("B*", $data);
	}
	shawrite($data, $nbits, $$self);
	return($self);
}

sub _bail {
	my $msg = shift;

        require Carp;
        Carp::croak("$msg: $!");
}

sub _addfile {  # this is "addfile" from Digest::base 1.00
    my ($self, $handle) = @_;

    my $n;
    my $buf = "";

    while (($n = read($handle, $buf, 4096))) {
        $self->add($buf);
    }
    _bail("Read failed") unless defined $n;

    $self;
}

sub Addfile {
	my ($self, $file, $mode) = @_;

	return(_addfile($self, $file)) unless ref(\$file) eq 'SCALAR';

	$mode = defined($mode) ? $mode : "";
	my ($binary, $portable) = map { $_ eq $mode } ("b", "p");

		## Always interpret "-" to mean STDIN; otherwise use
		## sysopen to handle full range of POSIX file names
	local *FH;
	$file eq '-' and open(FH, '< -')
		or sysopen(FH, $file, O_RDONLY)
			or _bail('Open failed');
	binmode(FH) if $binary || $portable;

	unless ($portable && -T $file) {
		$self->_addfile(*FH);
		close(FH);
		return($self);
	}

	my ($n1, $n2);
	my ($buf1, $buf2) = ("", "");

	while (($n1 = read(FH, $buf1, 4096))) {
		while (substr($buf1, -1) eq "\015") {
			$n2 = read(FH, $buf2, 4096);
			_bail("Read failed") unless defined $n2;
			last unless $n2;
			$buf1 .= $buf2;
		}
		$buf1 =~ s/\015?\015\012/\012/g;	# DOS/Windows
		$buf1 =~ s/\015/\012/g;			# early MacOS
		$self->add($buf1);
	}
	_bail("Read failed") unless defined $n1;
	close(FH);

	$self;
}

sub dump {
	my $self = shift;
	my $file = shift || "";

	shadump($file, $$self) || return;
	return($self);
}

sub load {
	my $class = shift;
	my $file = shift || "";
	if (ref($class)) {	# instance method
		shaclose($$class) if $$class;
		$$class = shaload($file) || return;
		return($class);
	}
	my $state = shaload($file) || return;
	my $self = \$state;
	bless($self, $class);
	return($self);
}

Digest::SHA->bootstrap($VERSION);

1;
__END__

#line 702
FILE   0c77a581/DynaLoader.pm  )�#line 1 "/usr/lib/perl/5.14/DynaLoader.pm"
# Generated from DynaLoader_pm.PL

package DynaLoader;

#   And Gandalf said: 'Many folk like to know beforehand what is to
#   be set on the table; but those who have laboured to prepare the
#   feast like to keep their secret; for wonder makes the words of
#   praise louder.'

#   (Quote from Tolkien suggested by Anno Siegel.)
#
# See pod text at end of file for documentation.
# See also ext/DynaLoader/README in source tree for other information.
#
# Tim.Bunce@ig.co.uk, August 1994

BEGIN {
    $VERSION = '1.13';
}

use Config;

# enable debug/trace messages from DynaLoader perl code
$dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

#
# Flags to alter dl_load_file behaviour.  Assigned bits:
#   0x01  make symbols available for linking later dl_load_file's.
#         (only known to work on Solaris 2 using dlopen(RTLD_GLOBAL))
#         (ignored under VMS; effect is built-in to image linking)
#
# This is called as a class method $module->dl_load_flags.  The
# definition here will be inherited and result on "default" loading
# behaviour unless a sub-class of DynaLoader defines its own version.
#

sub dl_load_flags { 0x00 }

($dl_dlext, $dl_so, $dlsrc) = @Config::Config{qw(dlext so dlsrc)};

$do_expand = 0;

@dl_require_symbols = ();       # names of symbols we need
@dl_resolve_using   = ();       # names of files to link with
@dl_library_path    = ();       # path to look for files

#XSLoader.pm may have added elements before we were required
#@dl_shared_objects  = ();       # shared objects for symbols we have 
#@dl_librefs         = ();       # things we have loaded
#@dl_modules         = ();       # Modules we have loaded

# This is a fix to support DLD's unfortunate desire to relink -lc
@dl_resolve_using = dl_findfile('-lc') if $dlsrc eq "dl_dld.xs";

# Initialise @dl_library_path with the 'standard' library path
# for this platform as determined by Configure.

push(@dl_library_path, split(' ', $Config::Config{libpth}));

my $ldlibpthname         = $Config::Config{ldlibpthname};
my $ldlibpthname_defined = defined $Config::Config{ldlibpthname};
my $pthsep               = $Config::Config{path_sep};

# Add to @dl_library_path any extra directories we can gather from environment
# during runtime.

if ($ldlibpthname_defined &&
    exists $ENV{$ldlibpthname}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{$ldlibpthname}));
}

# E.g. HP-UX supports both its native SHLIB_PATH *and* LD_LIBRARY_PATH.

if ($ldlibpthname_defined &&
    $ldlibpthname ne 'LD_LIBRARY_PATH' &&
    exists $ENV{LD_LIBRARY_PATH}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{LD_LIBRARY_PATH}));
}

# No prizes for guessing why we don't say 'bootstrap DynaLoader;' here.
# NOTE: All dl_*.xs (including dl_none.xs) define a dl_error() XSUB
boot_DynaLoader('DynaLoader') if defined(&boot_DynaLoader) &&
                                !defined(&dl_error);

if ($dl_debug) {
    print STDERR "DynaLoader.pm loaded (@INC, @dl_library_path)\n";
    print STDERR "DynaLoader not linked into this perl\n"
	    unless defined(&boot_DynaLoader);
}

1; # End of main code

sub croak   { require Carp; Carp::croak(@_)   }

sub bootstrap_inherit {
    my $module = $_[0];
    local *isa = *{"$module\::ISA"};
    local @isa = (@isa, 'DynaLoader');
    # Cannot goto due to delocalization.  Will report errors on a wrong line?
    bootstrap(@_);
}

sub bootstrap {
    # use local vars to enable $module.bs script to edit values
    local(@args) = @_;
    local($module) = $args[0];
    local(@dirs, $file);

    unless ($module) {
	require Carp;
	Carp::confess("Usage: DynaLoader::bootstrap(module)");
    }

    # A common error on platforms which don't support dynamic loading.
    # Since it's fatal and potentially confusing we give a detailed message.
    croak("Can't load module $module, dynamic loading not available in this perl.\n".
	"  (You may need to build a new perl executable which either supports\n".
	"  dynamic loading or has the $module module statically linked into it.)\n")
	unless defined(&dl_load_file);

    
    my @modparts = split(/::/,$module);
    my $modfname = $modparts[-1];

    # Some systems have restrictions on files names for DLL's etc.
    # mod2fname returns appropriate file base name (typically truncated)
    # It may also edit @modparts if required.
    $modfname = &mod2fname(\@modparts) if defined &mod2fname;

    

    my $modpname = join('/',@modparts);

    print STDERR "DynaLoader::bootstrap for $module ",
		       "(auto/$modpname/$modfname.$dl_dlext)\n"
	if $dl_debug;

    foreach (@INC) {
	
	    my $dir = "$_/auto/$modpname";
	
	next unless -d $dir; # skip over uninteresting directories
	
	# check for common cases to avoid autoload of dl_findfile
	my $try = "$dir/$modfname.$dl_dlext";
	last if $file = ($do_expand) ? dl_expandspec($try) : ((-f $try) && $try);
	
	# no luck here, save dir for possible later dl_findfile search
	push @dirs, $dir;
    }
    # last resort, let dl_findfile have a go in all known locations
    $file = dl_findfile(map("-L$_",@dirs,@INC), $modfname) unless $file;

    croak("Can't locate loadable object for module $module in \@INC (\@INC contains: @INC)")
	unless $file;	# wording similar to error from 'require'

    
    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @dl_require_symbols = ($bootname);

    # Execute optional '.bootstrap' perl script for this module.
    # The .bs file can be used to configure @dl_resolve_using etc to
    # match the needs of the individual module on this architecture.
    my $bs = $file;
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/; # look for .bs 'beside' the library
    if (-s $bs) { # only read file if it's not empty
        print STDERR "BS: $bs ($^O, $dlsrc)\n" if $dl_debug;
        eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    my $boot_symbol_ref;

    

    # Many dynamic extension loading problems will appear to come from
    # this section of code: XYZ failed at line 123 of DynaLoader.pm.
    # Often these errors are actually occurring in the initialisation
    # C code of the extension XS file. Perl reports the error as being
    # in this perl code simply because this was the last perl code
    # it executed.

    my $libref = dl_load_file($file, $module->dl_load_flags) or
	croak("Can't load '$file' for module $module: ".dl_error());

    push(@dl_librefs,$libref);  # record loaded object

    my @unresolved = dl_undef_symbols();
    if (@unresolved) {
	require Carp;
	Carp::carp("Undefined symbols present after loading $file: @unresolved\n");
    }

    $boot_symbol_ref = dl_find_symbol($libref, $bootname) or
         croak("Can't find '$bootname' symbol in $file\n");

    push(@dl_modules, $module); # record loaded module

  boot:
    my $xs = dl_install_xsub("${module}::bootstrap", $boot_symbol_ref, $file);

    # See comment block above

	push(@dl_shared_objects, $file); # record files loaded

    &$xs(@args);
}

sub dl_findfile {
    # Read ext/DynaLoader/DynaLoader.doc for detailed information.
    # This function does not automatically consider the architecture
    # or the perl library auto directories.
    my (@args) = @_;
    my (@dirs,  $dir);   # which directories to search
    my (@found);         # full paths to real files we have found
    #my $dl_ext= 'so'; # $Config::Config{'dlext'} suffix for perl extensions
    #my $dl_so = 'so'; # $Config::Config{'so'} suffix for shared libraries

    print STDERR "dl_findfile(@args)\n" if $dl_debug;

    # accumulate directories but process files as they appear
    arg: foreach(@args) {
        #  Special fast case: full filepath requires no search
	
	
        if (m:/: && -f $_) {
	    push(@found,$_);
	    last arg unless wantarray;
	    next;
	}
	

        # Deal with directories first:
        #  Using a -L prefix is the preferred option (faster and more robust)
        if (m:^-L:) { s/^-L//; push(@dirs, $_); next; }

        #  Otherwise we try to try to spot directories by a heuristic
        #  (this is a more complicated issue than it first appears)
        if (m:/: && -d $_) {   push(@dirs, $_); next; }

	

        #  Only files should get this far...
        my(@names, $name);    # what filenames to look for
        if (m:-l: ) {          # convert -lname to appropriate library name
            s/-l//;
            push(@names,"lib$_.$dl_so");
            push(@names,"lib$_.a");
        } else {                # Umm, a bare name. Try various alternatives:
            # these should be ordered with the most likely first
            push(@names,"$_.$dl_dlext")    unless m/\.$dl_dlext$/o;
            push(@names,"$_.$dl_so")     unless m/\.$dl_so$/o;
	    
            push(@names,"lib$_.$dl_so")  unless m:/:;
            push(@names,"$_.a")          if !m/\.a$/ and $dlsrc eq "dl_dld.xs";
            push(@names, $_);
        }
	my $dirsep = '/';
	
        foreach $dir (@dirs, @dl_library_path) {
            next unless -d $dir;
	    
            foreach $name (@names) {
		my($file) = "$dir$dirsep$name";
                print STDERR " checking in $dir for $name\n" if $dl_debug;
		$file = ($do_expand) ? dl_expandspec($file) : (-f $file && $file);
		#$file = _check_file($file);
		if ($file) {
                    push(@found, $file);
                    next arg; # no need to look any further
                }
            }
        }
    }
    if ($dl_debug) {
        foreach(@dirs) {
            print STDERR " dl_findfile ignored non-existent directory: $_\n" unless -d $_;
        }
        print STDERR "dl_findfile found: @found\n";
    }
    return $found[0] unless wantarray;
    @found;
}

sub dl_expandspec {
    my($spec) = @_;
    # Optional function invoked if DynaLoader.pm sets $do_expand.
    # Most systems do not require or use this function.
    # Some systems may implement it in the dl_*.xs file in which case
    # this Perl version should be excluded at build time.

    # This function is designed to deal with systems which treat some
    # 'filenames' in a special way. For example VMS 'Logical Names'
    # (something like unix environment variables - but different).
    # This function should recognise such names and expand them into
    # full file paths.
    # Must return undef if $spec is invalid or file does not exist.

    my $file = $spec; # default output to input

	return undef unless -f $file;
    print STDERR "dl_expandspec($spec) => $file\n" if $dl_debug;
    $file;
}

sub dl_find_symbol_anywhere
{
    my $sym = shift;
    my $libref;
    foreach $libref (@dl_librefs) {
	my $symref = dl_find_symbol($libref,$sym);
	return $symref if $symref;
    }
    return undef;
}

__END__

FILE   037b8ac0/Errno.pm  9#line 1 "/usr/lib/perl/5.14/Errno.pm"
# -*- buffer-read-only: t -*-
#
# This file is auto-generated. ***ANY*** changes here will be lost
#

package Errno;
require Exporter;
use strict;

our $VERSION = "1.13";
$VERSION = eval $VERSION;
our @ISA = 'Exporter';

my %err;

BEGIN {
    %err = (
	EPERM => 1,
	ENOENT => 2,
	ESRCH => 3,
	EINTR => 4,
	EIO => 5,
	ENXIO => 6,
	E2BIG => 7,
	ENOEXEC => 8,
	EBADF => 9,
	ECHILD => 10,
	EWOULDBLOCK => 11,
	EAGAIN => 11,
	ENOMEM => 12,
	EACCES => 13,
	EFAULT => 14,
	ENOTBLK => 15,
	EBUSY => 16,
	EEXIST => 17,
	EXDEV => 18,
	ENODEV => 19,
	ENOTDIR => 20,
	EISDIR => 21,
	EINVAL => 22,
	ENFILE => 23,
	EMFILE => 24,
	ENOTTY => 25,
	ETXTBSY => 26,
	EFBIG => 27,
	ENOSPC => 28,
	ESPIPE => 29,
	EROFS => 30,
	EMLINK => 31,
	EPIPE => 32,
	EDOM => 33,
	ERANGE => 34,
	EDEADLOCK => 35,
	EDEADLK => 35,
	ENAMETOOLONG => 36,
	ENOLCK => 37,
	ENOSYS => 38,
	ENOTEMPTY => 39,
	ELOOP => 40,
	ENOMSG => 42,
	EIDRM => 43,
	ECHRNG => 44,
	EL2NSYNC => 45,
	EL3HLT => 46,
	EL3RST => 47,
	ELNRNG => 48,
	EUNATCH => 49,
	ENOCSI => 50,
	EL2HLT => 51,
	EBADE => 52,
	EBADR => 53,
	EXFULL => 54,
	ENOANO => 55,
	EBADRQC => 56,
	EBADSLT => 57,
	EBFONT => 59,
	ENOSTR => 60,
	ENODATA => 61,
	ETIME => 62,
	ENOSR => 63,
	ENONET => 64,
	ENOPKG => 65,
	EREMOTE => 66,
	ENOLINK => 67,
	EADV => 68,
	ESRMNT => 69,
	ECOMM => 70,
	EPROTO => 71,
	EMULTIHOP => 72,
	EDOTDOT => 73,
	EBADMSG => 74,
	EOVERFLOW => 75,
	ENOTUNIQ => 76,
	EBADFD => 77,
	EREMCHG => 78,
	ELIBACC => 79,
	ELIBBAD => 80,
	ELIBSCN => 81,
	ELIBMAX => 82,
	ELIBEXEC => 83,
	EILSEQ => 84,
	ERESTART => 85,
	ESTRPIPE => 86,
	EUSERS => 87,
	ENOTSOCK => 88,
	EDESTADDRREQ => 89,
	EMSGSIZE => 90,
	EPROTOTYPE => 91,
	ENOPROTOOPT => 92,
	EPROTONOSUPPORT => 93,
	ESOCKTNOSUPPORT => 94,
	ENOTSUP => 95,
	EOPNOTSUPP => 95,
	EPFNOSUPPORT => 96,
	EAFNOSUPPORT => 97,
	EADDRINUSE => 98,
	EADDRNOTAVAIL => 99,
	ENETDOWN => 100,
	ENETUNREACH => 101,
	ENETRESET => 102,
	ECONNABORTED => 103,
	ECONNRESET => 104,
	ENOBUFS => 105,
	EISCONN => 106,
	ENOTCONN => 107,
	ESHUTDOWN => 108,
	ETOOMANYREFS => 109,
	ETIMEDOUT => 110,
	ECONNREFUSED => 111,
	EHOSTDOWN => 112,
	EHOSTUNREACH => 113,
	EALREADY => 114,
	EINPROGRESS => 115,
	ESTALE => 116,
	EUCLEAN => 117,
	ENOTNAM => 118,
	ENAVAIL => 119,
	EISNAM => 120,
	EREMOTEIO => 121,
	EDQUOT => 122,
	ENOMEDIUM => 123,
	EMEDIUMTYPE => 124,
	ECANCELED => 125,
	ENOKEY => 126,
	EKEYEXPIRED => 127,
	EKEYREVOKED => 128,
	EKEYREJECTED => 129,
	EOWNERDEAD => 130,
	ENOTRECOVERABLE => 131,
	ERFKILL => 132,
	EHWPOISON => 133,
    );
    # Generate proxy constant subroutines for all the values.
    # Well, almost all the values. Unfortunately we can't assume that at this
    # point that our symbol table is empty, as code such as if the parser has
    # seen code such as C<exists &Errno::EINVAL>, it will have created the
    # typeglob.
    # Doing this before defining @EXPORT_OK etc means that even if a platform is
    # crazy enough to define EXPORT_OK as an error constant, everything will
    # still work, because the parser will upgrade the PCS to a real typeglob.
    # We rely on the subroutine definitions below to update the internal caches.
    # Don't use %each, as we don't want a copy of the value.
    foreach my $name (keys %err) {
        if ($Errno::{$name}) {
            # We expect this to be reached fairly rarely, so take an approach
            # which uses the least compile time effort in the common case:
            eval "sub $name() { $err{$name} }; 1" or die $@;
        } else {
            $Errno::{$name} = \$err{$name};
        }
    }
}

our @EXPORT_OK = keys %err;

our %EXPORT_TAGS = (
    POSIX => [qw(
	E2BIG EACCES EADDRINUSE EADDRNOTAVAIL EAFNOSUPPORT EAGAIN EALREADY
	EBADF EBUSY ECHILD ECONNABORTED ECONNREFUSED ECONNRESET EDEADLK
	EDESTADDRREQ EDOM EDQUOT EEXIST EFAULT EFBIG EHOSTDOWN EHOSTUNREACH
	EINPROGRESS EINTR EINVAL EIO EISCONN EISDIR ELOOP EMFILE EMLINK
	EMSGSIZE ENAMETOOLONG ENETDOWN ENETRESET ENETUNREACH ENFILE ENOBUFS
	ENODEV ENOENT ENOEXEC ENOLCK ENOMEM ENOPROTOOPT ENOSPC ENOSYS ENOTBLK
	ENOTCONN ENOTDIR ENOTEMPTY ENOTSOCK ENOTTY ENXIO EOPNOTSUPP EPERM
	EPFNOSUPPORT EPIPE EPROTONOSUPPORT EPROTOTYPE ERANGE EREMOTE ERESTART
	EROFS ESHUTDOWN ESOCKTNOSUPPORT ESPIPE ESRCH ESTALE ETIMEDOUT
	ETOOMANYREFS ETXTBSY EUSERS EWOULDBLOCK EXDEV
    )]
);

sub TIEHASH { bless \%err }

sub FETCH {
    my (undef, $errname) = @_;
    return "" unless exists $err{$errname};
    my $errno = $err{$errname};
    return $errno == $! ? $errno : 0;
}

sub STORE {
    require Carp;
    Carp::confess("ERRNO hash is read only!");
}

*CLEAR = *DELETE = \*STORE; # Typeglob aliasing uses less space

sub NEXTKEY {
    each %err;
}

sub FIRSTKEY {
    my $s = scalar keys %err;	# initialize iterator
    each %err;
}

sub EXISTS {
    my (undef, $errname) = @_;
    exists $err{$errname};
}

tie %!, __PACKAGE__; # Returns an object, objects are true.

__END__

# ex: set ro:
FILE   2b1a9457/Fcntl.pm  #line 1 "/usr/lib/perl/5.14/Fcntl.pm"
package Fcntl;

use strict;
our($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

require Exporter;
require XSLoader;
@ISA = qw(Exporter);
$VERSION = '1.11';

XSLoader::load();

# Named groups of exports
%EXPORT_TAGS = (
    'flock'   => [qw(LOCK_SH LOCK_EX LOCK_NB LOCK_UN)],
    'Fcompat' => [qw(FAPPEND FASYNC FCREAT FDEFER FDSYNC FEXCL FLARGEFILE
		     FNDELAY FNONBLOCK FRSYNC FSYNC FTRUNC)],
    'seek'    => [qw(SEEK_SET SEEK_CUR SEEK_END)],
    'mode'    => [qw(S_ISUID S_ISGID S_ISVTX S_ISTXT
		     _S_IFMT S_IFREG S_IFDIR S_IFLNK
		     S_IFSOCK S_IFBLK S_IFCHR S_IFIFO S_IFWHT S_ENFMT
		     S_IRUSR S_IWUSR S_IXUSR S_IRWXU
		     S_IRGRP S_IWGRP S_IXGRP S_IRWXG
		     S_IROTH S_IWOTH S_IXOTH S_IRWXO
		     S_IREAD S_IWRITE S_IEXEC
		     S_ISREG S_ISDIR S_ISLNK S_ISSOCK
		     S_ISBLK S_ISCHR S_ISFIFO
		     S_ISWHT S_ISENFMT		
		     S_IFMT S_IMODE
                  )],
);

# Items to export into callers namespace by default
# (move infrequently used names to @EXPORT_OK below)
@EXPORT =
  qw(
	FD_CLOEXEC
	F_ALLOCSP
	F_ALLOCSP64
	F_COMPAT
	F_DUP2FD
	F_DUPFD
	F_EXLCK
	F_FREESP
	F_FREESP64
	F_FSYNC
	F_FSYNC64
	F_GETFD
	F_GETFL
	F_GETLK
	F_GETLK64
	F_GETOWN
	F_NODNY
	F_POSIX
	F_RDACC
	F_RDDNY
	F_RDLCK
	F_RWACC
	F_RWDNY
	F_SETFD
	F_SETFL
	F_SETLK
	F_SETLK64
	F_SETLKW
	F_SETLKW64
	F_SETOWN
	F_SHARE
	F_SHLCK
	F_UNLCK
	F_UNSHARE
	F_WRACC
	F_WRDNY
	F_WRLCK
	O_ACCMODE
	O_ALIAS
	O_APPEND
	O_ASYNC
	O_BINARY
	O_CREAT
	O_DEFER
	O_DIRECT
	O_DIRECTORY
	O_DSYNC
	O_EXCL
	O_EXLOCK
	O_LARGEFILE
	O_NDELAY
	O_NOCTTY
	O_NOFOLLOW
	O_NOINHERIT
	O_NONBLOCK
	O_RANDOM
	O_RAW
	O_RDONLY
	O_RDWR
	O_RSRC
	O_RSYNC
	O_SEQUENTIAL
	O_SHLOCK
	O_SYNC
	O_TEMPORARY
	O_TEXT
	O_TRUNC
	O_WRONLY
     );

# Other items we are prepared to export if requested
@EXPORT_OK = (qw(
	DN_ACCESS
	DN_ATTRIB
	DN_CREATE
	DN_DELETE
	DN_MODIFY
	DN_MULTISHOT
	DN_RENAME
	F_GETLEASE
	F_GETSIG
	F_NOTIFY
	F_SETLEASE
	F_SETSIG
	LOCK_MAND
	LOCK_READ
	LOCK_RW
	LOCK_WRITE
	O_IGNORE_CTTY
	O_NOATIME
	O_NOLINK
	O_NOTRANS
), map {@{$_}} values %EXPORT_TAGS);

1;
FILE   6f095d2b/File/Glob.pm  �#line 1 "/usr/lib/perl/5.14/File/Glob.pm"
package File::Glob;

use strict;
our($VERSION, @ISA, @EXPORT_OK, @EXPORT_FAIL, %EXPORT_TAGS, $DEFAULT_FLAGS);

require XSLoader;
use feature 'switch';

@ISA = qw(Exporter);

# NOTE: The glob() export is only here for compatibility with 5.6.0.
# csh_glob() should not be used directly, unless you know what you're doing.

%EXPORT_TAGS = (
    'glob' => [ qw(
        GLOB_ABEND
	GLOB_ALPHASORT
        GLOB_ALTDIRFUNC
        GLOB_BRACE
        GLOB_CSH
        GLOB_ERR
        GLOB_ERROR
        GLOB_LIMIT
        GLOB_MARK
        GLOB_NOCASE
        GLOB_NOCHECK
        GLOB_NOMAGIC
        GLOB_NOSORT
        GLOB_NOSPACE
        GLOB_QUOTE
        GLOB_TILDE
        glob
        bsd_glob
    ) ],
);

@EXPORT_OK   = (@{$EXPORT_TAGS{'glob'}}, 'csh_glob');

$VERSION = '1.13';

sub import {
    require Exporter;
    local $Exporter::ExportLevel = $Exporter::ExportLevel + 1;
    Exporter::import(grep {
	my $passthrough;
	given ($_) {
	    $DEFAULT_FLAGS &= ~GLOB_NOCASE() when ':case';
	    $DEFAULT_FLAGS |= GLOB_NOCASE() when ':nocase';
	    when (':globally') {
		no warnings 'redefine';
		*CORE::GLOBAL::glob = \&File::Glob::csh_glob;
	    }
	    $passthrough = 1;
	}
	$passthrough;
    } @_);
}

XSLoader::load();

$DEFAULT_FLAGS = GLOB_CSH();
if ($^O =~ /^(?:MSWin32|VMS|os2|dos|riscos)$/) {
    $DEFAULT_FLAGS |= GLOB_NOCASE();
}

# File::Glob::glob() is deprecated because its prototype is different from
# CORE::glob() (use bsd_glob() instead)
sub glob {
    splice @_, 1; # don't pass PL_glob_index as flags!
    goto &bsd_glob;
}

## borrowed heavily from gsar's File::DosGlob
my %iter;
my %entries;

sub csh_glob {
    my $pat = shift;
    my $cxix = shift;
    my @pat;

    # glob without args defaults to $_
    $pat = $_ unless defined $pat;

    # extract patterns
    $pat =~ s/^\s+//;	# Protect against empty elements in
    $pat =~ s/\s+$//;	# things like < *.c> and <*.c >.
			# These alone shouldn't trigger ParseWords.
    if ($pat =~ /\s/) {
        # XXX this is needed for compatibility with the csh
	# implementation in Perl.  Need to support a flag
	# to disable this behavior.
	require Text::ParseWords;
	@pat = Text::ParseWords::parse_line('\s+',0,$pat);
    }

    # assume global context if not provided one
    $cxix = '_G_' unless defined $cxix;
    $iter{$cxix} = 0 unless exists $iter{$cxix};

    # if we're just beginning, do it all first
    if ($iter{$cxix} == 0) {
	if (@pat) {
	    $entries{$cxix} = [ map { doglob($_, $DEFAULT_FLAGS) } @pat ];
	}
	else {
	    $entries{$cxix} = [ doglob($pat, $DEFAULT_FLAGS) ];
	}
    }

    # chuck it all out, quick or slow
    if (wantarray) {
        delete $iter{$cxix};
        return @{delete $entries{$cxix}};
    }
    else {
        if ($iter{$cxix} = scalar @{$entries{$cxix}}) {
            return shift @{$entries{$cxix}};
        }
        else {
            # return undef for EOL
            delete $iter{$cxix};
            delete $entries{$cxix};
            return undef;
        }
    }
}

1;
__END__

FILE   7fcdf589/File/Spec.pm  }#line 1 "/usr/lib/perl/5.14/File/Spec.pm"
package File::Spec;

use strict;
use vars qw(@ISA $VERSION);

$VERSION = '3.33';
$VERSION = eval $VERSION;

my %module = (MacOS   => 'Mac',
	      MSWin32 => 'Win32',
	      os2     => 'OS2',
	      VMS     => 'VMS',
	      epoc    => 'Epoc',
	      NetWare => 'Win32', # Yes, File::Spec::Win32 works on NetWare.
	      symbian => 'Win32', # Yes, File::Spec::Win32 works on symbian.
	      dos     => 'OS2',   # Yes, File::Spec::OS2 works on DJGPP.
	      cygwin  => 'Cygwin');

my $module = $module{$^O} || 'Unix';

require "File/Spec/$module.pm";
@ISA = ("File::Spec::$module");

1;

__END__

FILE   b353540f/File/Spec/Unix.pm  �#line 1 "/usr/lib/perl/5.14/File/Spec/Unix.pm"
package File::Spec::Unix;

use strict;
use vars qw($VERSION);

$VERSION = '3.33';
$VERSION = eval $VERSION;

sub canonpath {
    my ($self,$path) = @_;
    return unless defined $path;
    
    # Handle POSIX-style node names beginning with double slash (qnx, nto)
    # (POSIX says: "a pathname that begins with two successive slashes
    # may be interpreted in an implementation-defined manner, although
    # more than two leading slashes shall be treated as a single slash.")
    my $node = '';
    my $double_slashes_special = $^O eq 'qnx' || $^O eq 'nto';

    if ( $double_slashes_special
         && ( $path =~ s{^(//[^/]+)/?\z}{}s || $path =~ s{^(//[^/]+)/}{/}s ) ) {
      $node = $1;
    }
    # This used to be
    # $path =~ s|/+|/|g unless ($^O eq 'cygwin');
    # but that made tests 29, 30, 35, 46, and 213 (as of #13272) to fail
    # (Mainly because trailing "" directories didn't get stripped).
    # Why would cygwin avoid collapsing multiple slashes into one? --jhi
    $path =~ s|/{2,}|/|g;                            # xx////xx  -> xx/xx
    $path =~ s{(?:/\.)+(?:/|\z)}{/}g;                # xx/././xx -> xx/xx
    $path =~ s|^(?:\./)+||s unless $path eq "./";    # ./xx      -> xx
    $path =~ s|^/(?:\.\./)+|/|;                      # /../../xx -> xx
    $path =~ s|^/\.\.$|/|;                         # /..       -> /
    $path =~ s|/\z|| unless $path eq "/";          # xx/       -> xx
    return "$node$path";
}

sub catdir {
    my $self = shift;

    $self->canonpath(join('/', @_, '')); # '' because need a trailing '/'
}

sub catfile {
    my $self = shift;
    my $file = $self->canonpath(pop @_);
    return $file unless @_;
    my $dir = $self->catdir(@_);
    $dir .= "/" unless substr($dir,-1) eq "/";
    return $dir.$file;
}

sub curdir { '.' }

sub devnull { '/dev/null' }

sub rootdir { '/' }

my $tmpdir;
sub _tmpdir {
    return $tmpdir if defined $tmpdir;
    my $self = shift;
    my @dirlist = @_;
    {
	no strict 'refs';
	if (${"\cTAINT"}) { # Check for taint mode on perl >= 5.8.0
            require Scalar::Util;
	    @dirlist = grep { ! Scalar::Util::tainted($_) } @dirlist;
	}
    }
    foreach (@dirlist) {
	next unless defined && -d && -w _;
	$tmpdir = $_;
	last;
    }
    $tmpdir = $self->curdir unless defined $tmpdir;
    $tmpdir = defined $tmpdir && $self->canonpath($tmpdir);
    return $tmpdir;
}

sub tmpdir {
    return $tmpdir if defined $tmpdir;
    $tmpdir = $_[0]->_tmpdir( $ENV{TMPDIR}, "/tmp" );
}

sub updir { '..' }

sub no_upwards {
    my $self = shift;
    return grep(!/^\.{1,2}\z/s, @_);
}

sub case_tolerant { 0 }

sub file_name_is_absolute {
    my ($self,$file) = @_;
    return scalar($file =~ m:^/:s);
}

sub path {
    return () unless exists $ENV{PATH};
    my @path = split(':', $ENV{PATH});
    foreach (@path) { $_ = '.' if $_ eq '' }
    return @path;
}

sub join {
    my $self = shift;
    return $self->catfile(@_);
}

sub splitpath {
    my ($self,$path, $nofile) = @_;

    my ($volume,$directory,$file) = ('','','');

    if ( $nofile ) {
        $directory = $path;
    }
    else {
        $path =~ m|^ ( (?: .* / (?: \.\.?\z )? )? ) ([^/]*) |xs;
        $directory = $1;
        $file      = $2;
    }

    return ($volume,$directory,$file);
}

sub splitdir {
    return split m|/|, $_[1], -1;  # Preserve trailing fields
}

sub catpath {
    my ($self,$volume,$directory,$file) = @_;

    if ( $directory ne ''                && 
         $file ne ''                     && 
         substr( $directory, -1 ) ne '/' && 
         substr( $file, 0, 1 ) ne '/' 
    ) {
        $directory .= "/$file" ;
    }
    else {
        $directory .= $file ;
    }

    return $directory ;
}

sub abs2rel {
    my($self,$path,$base) = @_;
    $base = $self->_cwd() unless defined $base and length $base;

    ($path, $base) = map $self->canonpath($_), $path, $base;

    if (grep $self->file_name_is_absolute($_), $path, $base) {
	($path, $base) = map $self->rel2abs($_), $path, $base;
    }
    else {
	# save a couple of cwd()s if both paths are relative
	($path, $base) = map $self->catdir('/', $_), $path, $base;
    }

    my ($path_volume) = $self->splitpath($path, 1);
    my ($base_volume) = $self->splitpath($base, 1);

    # Can't relativize across volumes
    return $path unless $path_volume eq $base_volume;

    my $path_directories = ($self->splitpath($path, 1))[1];
    my $base_directories = ($self->splitpath($base, 1))[1];

    # For UNC paths, the user might give a volume like //foo/bar that
    # strictly speaking has no directory portion.  Treat it as if it
    # had the root directory for that volume.
    if (!length($base_directories) and $self->file_name_is_absolute($base)) {
      $base_directories = $self->rootdir;
    }

    # Now, remove all leading components that are the same
    my @pathchunks = $self->splitdir( $path_directories );
    my @basechunks = $self->splitdir( $base_directories );

    if ($base_directories eq $self->rootdir) {
      shift @pathchunks;
      return $self->canonpath( $self->catpath('', $self->catdir( @pathchunks ), '') );
    }

    while (@pathchunks && @basechunks && $self->_same($pathchunks[0], $basechunks[0])) {
        shift @pathchunks ;
        shift @basechunks ;
    }
    return $self->curdir unless @pathchunks || @basechunks;

    # $base now contains the directories the resulting relative path 
    # must ascend out of before it can descend to $path_directory.
    my $result_dirs = $self->catdir( ($self->updir) x @basechunks, @pathchunks );
    return $self->canonpath( $self->catpath('', $result_dirs, '') );
}

sub _same {
  $_[1] eq $_[2];
}

sub rel2abs {
    my ($self,$path,$base ) = @_;

    # Clean up $path
    if ( ! $self->file_name_is_absolute( $path ) ) {
        # Figure out the effective $base and clean it up.
        if ( !defined( $base ) || $base eq '' ) {
	    $base = $self->_cwd();
        }
        elsif ( ! $self->file_name_is_absolute( $base ) ) {
            $base = $self->rel2abs( $base ) ;
        }
        else {
            $base = $self->canonpath( $base ) ;
        }

        # Glom them together
        $path = $self->catdir( $base, $path ) ;
    }

    return $self->canonpath( $path ) ;
}

# Internal routine to File::Spec, no point in making this public since
# it is the standard Cwd interface.  Most of the platform-specific
# File::Spec subclasses use this.
sub _cwd {
    require Cwd;
    Cwd::getcwd();
}

# Internal method to reduce xx\..\yy -> yy
sub _collapse {
    my($fs, $path) = @_;

    my $updir  = $fs->updir;
    my $curdir = $fs->curdir;

    my($vol, $dirs, $file) = $fs->splitpath($path);
    my @dirs = $fs->splitdir($dirs);
    pop @dirs if @dirs && $dirs[-1] eq '';

    my @collapsed;
    foreach my $dir (@dirs) {
        if( $dir eq $updir              and   # if we have an updir
            @collapsed                  and   # and something to collapse
            length $collapsed[-1]       and   # and its not the rootdir
            $collapsed[-1] ne $updir    and   # nor another updir
            $collapsed[-1] ne $curdir         # nor the curdir
          ) 
        {                                     # then
            pop @collapsed;                   # collapse
        }
        else {                                # else
            push @collapsed, $dir;            # just hang onto it
        }
    }

    return $fs->catpath($vol,
                        $fs->catdir(@collapsed),
                        $file
                       );
}

1;
FILE   51ffad0c/IO.pm  �#line 1 "/usr/lib/perl/5.14/IO.pm"
#

package IO;

use XSLoader ();
use Carp;
use strict;
use warnings;

our $VERSION = "1.25_04";
XSLoader::load 'IO', $VERSION;

sub import {
    shift;

    warnings::warnif('deprecated', qq{Parameterless "use IO" deprecated})
        if @_ == 0 ;
    
    my @l = @_ ? @_ : qw(Handle Seekable File Pipe Socket Dir);

    eval join("", map { "require IO::" . (/(\w+)/)[0] . ";\n" } @l)
	or croak $@;
}

1;

__END__

FILE   50e3181c/IO/File.pm  �#line 1 "/usr/lib/perl/5.14/IO/File.pm"
#

package IO::File;

use 5.006_001;
use strict;
our($VERSION, @EXPORT, @EXPORT_OK, @ISA);
use Carp;
use Symbol;
use SelectSaver;
use IO::Seekable;
use File::Spec;

require Exporter;

@ISA = qw(IO::Handle IO::Seekable Exporter);

$VERSION = "1.15";

@EXPORT = @IO::Seekable::EXPORT;

eval {
    # Make all Fcntl O_XXX constants available for importing
    require Fcntl;
    my @O = grep /^O_/, @Fcntl::EXPORT;
    Fcntl->import(@O);  # first we import what we want to export
    push(@EXPORT, @O);
};

################################################
## Constructor
##

sub new {
    my $type = shift;
    my $class = ref($type) || $type || "IO::File";
    @_ >= 0 && @_ <= 3
	or croak "usage: $class->new([FILENAME [,MODE [,PERMS]]])";
    my $fh = $class->SUPER::new();
    if (@_) {
	$fh->open(@_)
	    or return undef;
    }
    $fh;
}

################################################
## Open
##

sub open {
    @_ >= 2 && @_ <= 4 or croak 'usage: $fh->open(FILENAME [,MODE [,PERMS]])';
    my ($fh, $file) = @_;
    if (@_ > 2) {
	my ($mode, $perms) = @_[2, 3];
	if ($mode =~ /^\d+$/) {
	    defined $perms or $perms = 0666;
	    return sysopen($fh, $file, $mode, $perms);
	} elsif ($mode =~ /:/) {
	    return open($fh, $mode, $file) if @_ == 3;
	    croak 'usage: $fh->open(FILENAME, IOLAYERS)';
	} else {
            return open($fh, IO::Handle::_open_mode_string($mode), $file);
        }
    }
    open($fh, $file);
}

################################################
## Binmode
##

sub binmode {
    ( @_ == 1 or @_ == 2 ) or croak 'usage $fh->binmode([LAYER])';

    my($fh, $layer) = @_;

    return binmode $$fh unless $layer;
    return binmode $$fh, $layer;
}

1;
FILE   b317ecf9/IO/Handle.pm  �#line 1 "/usr/lib/perl/5.14/IO/Handle.pm"
package IO::Handle;

use 5.006_001;
use strict;
our($VERSION, @EXPORT_OK, @ISA);
use Carp;
use Symbol;
use SelectSaver;
use IO ();	# Load the XS module

require Exporter;
@ISA = qw(Exporter);

$VERSION = "1.31";
$VERSION = eval $VERSION;

@EXPORT_OK = qw(
    autoflush
    output_field_separator
    output_record_separator
    input_record_separator
    input_line_number
    format_page_number
    format_lines_per_page
    format_lines_left
    format_name
    format_top_name
    format_line_break_characters
    format_formfeed
    format_write

    print
    printf
    say
    getline
    getlines

    printflush
    flush

    SEEK_SET
    SEEK_CUR
    SEEK_END
    _IOFBF
    _IOLBF
    _IONBF
);

################################################
## Constructors, destructors.
##

sub new {
    my $class = ref($_[0]) || $_[0] || "IO::Handle";
    if (@_ != 1) {
	# Since perl will automatically require IO::File if needed, but
	# also initialises IO::File's @ISA as part of the core we must
	# ensure IO::File is loaded if IO::Handle is. This avoids effect-
	# ively "half-loading" IO::File.
	if ($] > 5.013 && $class eq 'IO::File' && !$INC{"IO/File.pm"}) {
	    require IO::File;
	    shift;
	    return IO::File::->new(@_);
	}
	croak "usage: $class->new()";
    }
    my $io = gensym;
    bless $io, $class;
}

sub new_from_fd {
    my $class = ref($_[0]) || $_[0] || "IO::Handle";
    @_ == 3 or croak "usage: $class->new_from_fd(FD, MODE)";
    my $io = gensym;
    shift;
    IO::Handle::fdopen($io, @_)
	or return undef;
    bless $io, $class;
}

#
# There is no need for DESTROY to do anything, because when the
# last reference to an IO object is gone, Perl automatically
# closes its associated files (if any).  However, to avoid any
# attempts to autoload DESTROY, we here define it to do nothing.
#
sub DESTROY {}

################################################
## Open and close.
##

sub _open_mode_string {
    my ($mode) = @_;
    $mode =~ /^\+?(<|>>?)$/
      or $mode =~ s/^r(\+?)$/$1</
      or $mode =~ s/^w(\+?)$/$1>/
      or $mode =~ s/^a(\+?)$/$1>>/
      or croak "IO::Handle: bad open mode: $mode";
    $mode;
}

sub fdopen {
    @_ == 3 or croak 'usage: $io->fdopen(FD, MODE)';
    my ($io, $fd, $mode) = @_;
    local(*GLOB);

    if (ref($fd) && "".$fd =~ /GLOB\(/o) {
	# It's a glob reference; Alias it as we cannot get name of anon GLOBs
	my $n = qualify(*GLOB);
	*GLOB = *{*$fd};
	$fd =  $n;
    } elsif ($fd =~ m#^\d+$#) {
	# It's an FD number; prefix with "=".
	$fd = "=$fd";
    }

    open($io, _open_mode_string($mode) . '&' . $fd)
	? $io : undef;
}

sub close {
    @_ == 1 or croak 'usage: $io->close()';
    my($io) = @_;

    close($io);
}

################################################
## Normal I/O functions.
##

# flock
# select

sub opened {
    @_ == 1 or croak 'usage: $io->opened()';
    defined fileno($_[0]);
}

sub fileno {
    @_ == 1 or croak 'usage: $io->fileno()';
    fileno($_[0]);
}

sub getc {
    @_ == 1 or croak 'usage: $io->getc()';
    getc($_[0]);
}

sub eof {
    @_ == 1 or croak 'usage: $io->eof()';
    eof($_[0]);
}

sub print {
    @_ or croak 'usage: $io->print(ARGS)';
    my $this = shift;
    print $this @_;
}

sub printf {
    @_ >= 2 or croak 'usage: $io->printf(FMT,[ARGS])';
    my $this = shift;
    printf $this @_;
}

sub say {
    @_ or croak 'usage: $io->say(ARGS)';
    my $this = shift;
    local $\ = "\n";
    print $this @_;
}

sub getline {
    @_ == 1 or croak 'usage: $io->getline()';
    my $this = shift;
    return scalar <$this>;
} 

*gets = \&getline;  # deprecated

sub getlines {
    @_ == 1 or croak 'usage: $io->getlines()';
    wantarray or
	croak 'Can\'t call $io->getlines in a scalar context, use $io->getline';
    my $this = shift;
    return <$this>;
}

sub truncate {
    @_ == 2 or croak 'usage: $io->truncate(LEN)';
    truncate($_[0], $_[1]);
}

sub read {
    @_ == 3 || @_ == 4 or croak 'usage: $io->read(BUF, LEN [, OFFSET])';
    read($_[0], $_[1], $_[2], $_[3] || 0);
}

sub sysread {
    @_ == 3 || @_ == 4 or croak 'usage: $io->sysread(BUF, LEN [, OFFSET])';
    sysread($_[0], $_[1], $_[2], $_[3] || 0);
}

sub write {
    @_ >= 2 && @_ <= 4 or croak 'usage: $io->write(BUF [, LEN [, OFFSET]])';
    local($\) = "";
    $_[2] = length($_[1]) unless defined $_[2];
    print { $_[0] } substr($_[1], $_[3] || 0, $_[2]);
}

sub syswrite {
    @_ >= 2 && @_ <= 4 or croak 'usage: $io->syswrite(BUF [, LEN [, OFFSET]])';
    if (defined($_[2])) {
	syswrite($_[0], $_[1], $_[2], $_[3] || 0);
    } else {
	syswrite($_[0], $_[1]);
    }
}

sub stat {
    @_ == 1 or croak 'usage: $io->stat()';
    stat($_[0]);
}

################################################
## State modification functions.
##

sub autoflush {
    my $old = new SelectSaver qualify($_[0], caller);
    my $prev = $|;
    $| = @_ > 1 ? $_[1] : 1;
    $prev;
}

sub output_field_separator {
    carp "output_field_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $,;
    $, = $_[1] if @_ > 1;
    $prev;
}

sub output_record_separator {
    carp "output_record_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $\;
    $\ = $_[1] if @_ > 1;
    $prev;
}

sub input_record_separator {
    carp "input_record_separator is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $/;
    $/ = $_[1] if @_ > 1;
    $prev;
}

sub input_line_number {
    local $.;
    () = tell qualify($_[0], caller) if ref($_[0]);
    my $prev = $.;
    $. = $_[1] if @_ > 1;
    $prev;
}

sub format_page_number {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $%;
    $% = $_[1] if @_ > 1;
    $prev;
}

sub format_lines_per_page {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $=;
    $= = $_[1] if @_ > 1;
    $prev;
}

sub format_lines_left {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $-;
    $- = $_[1] if @_ > 1;
    $prev;
}

sub format_name {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $~;
    $~ = qualify($_[1], caller) if @_ > 1;
    $prev;
}

sub format_top_name {
    my $old;
    $old = new SelectSaver qualify($_[0], caller) if ref($_[0]);
    my $prev = $^;
    $^ = qualify($_[1], caller) if @_ > 1;
    $prev;
}

sub format_line_break_characters {
    carp "format_line_break_characters is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $:;
    $: = $_[1] if @_ > 1;
    $prev;
}

sub format_formfeed {
    carp "format_formfeed is not supported on a per-handle basis"
	if ref($_[0]);
    my $prev = $^L;
    $^L = $_[1] if @_ > 1;
    $prev;
}

sub formline {
    my $io = shift;
    my $picture = shift;
    local($^A) = $^A;
    local($\) = "";
    formline($picture, @_);
    print $io $^A;
}

sub format_write {
    @_ < 3 || croak 'usage: $io->write( [FORMAT_NAME] )';
    if (@_ == 2) {
	my ($io, $fmt) = @_;
	my $oldfmt = $io->format_name(qualify($fmt,caller));
	CORE::write($io);
	$io->format_name($oldfmt);
    } else {
	CORE::write($_[0]);
    }
}

sub fcntl {
    @_ == 3 || croak 'usage: $io->fcntl( OP, VALUE );';
    my ($io, $op) = @_;
    return fcntl($io, $op, $_[2]);
}

sub ioctl {
    @_ == 3 || croak 'usage: $io->ioctl( OP, VALUE );';
    my ($io, $op) = @_;
    return ioctl($io, $op, $_[2]);
}

# this sub is for compatibility with older releases of IO that used
# a sub called constant to determine if a constant existed -- GMB
#
# The SEEK_* and _IO?BF constants were the only constants at that time
# any new code should just chech defined(&CONSTANT_NAME)

sub constant {
    no strict 'refs';
    my $name = shift;
    (($name =~ /^(SEEK_(SET|CUR|END)|_IO[FLN]BF)$/) && defined &{$name})
	? &{$name}() : undef;
}

# so that flush.pl can be deprecated

sub printflush {
    my $io = shift;
    my $old;
    $old = new SelectSaver qualify($io, caller) if ref($io);
    local $| = 1;
    if(ref($io)) {
        print $io @_;
    }
    else {
	print @_;
    }
}

1;
FILE   7e34446d/IO/Seekable.pm  �#line 1 "/usr/lib/perl/5.14/IO/Seekable.pm"
#

package IO::Seekable;

use 5.006_001;
use Carp;
use strict;
our($VERSION, @EXPORT, @ISA);
use IO::Handle ();
# XXX we can't get these from IO::Handle or we'll get prototype
# mismatch warnings on C<use POSIX; use IO::File;> :-(
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);
require Exporter;

@EXPORT = qw(SEEK_SET SEEK_CUR SEEK_END);
@ISA = qw(Exporter);

$VERSION = "1.10";
$VERSION = eval $VERSION;

sub seek {
    @_ == 3 or croak 'usage: $io->seek(POS, WHENCE)';
    seek($_[0], $_[1], $_[2]);
}

sub sysseek {
    @_ == 3 or croak 'usage: $io->sysseek(POS, WHENCE)';
    sysseek($_[0], $_[1], $_[2]);
}

sub tell {
    @_ == 1 or croak 'usage: $io->tell()';
    tell($_[0]);
}

1;
FILE   827561d6/List/Util.pm  T#line 1 "/usr/lib/perl/5.14/List/Util.pm"
# List::Util.pm
#
# Copyright (c) 1997-2009 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
# This module is normally only loaded if the XS module is not available

package List::Util;

use strict;
use vars qw(@ISA @EXPORT_OK $VERSION $XS_VERSION $TESTING_PERL_ONLY);
require Exporter;

@ISA        = qw(Exporter);
@EXPORT_OK  = qw(first min max minstr maxstr reduce sum shuffle);
$VERSION    = "1.23";
$XS_VERSION = $VERSION;
$VERSION    = eval $VERSION;

eval {
  # PERL_DL_NONLAZY must be false, or any errors in loading will just
  # cause the perl code to be tested
  local $ENV{PERL_DL_NONLAZY} = 0 if $ENV{PERL_DL_NONLAZY};
  eval {
    require XSLoader;
    XSLoader::load('List::Util', $XS_VERSION);
    1;
  } or do {
    require DynaLoader;
    local @ISA = qw(DynaLoader);
    bootstrap List::Util $XS_VERSION;
  };
} unless $TESTING_PERL_ONLY;

if (!defined &sum) {
  require List::Util::PP;
  List::Util::PP->import;
}

1;

__END__

FILE   82d64c88/MIME/Base64.pm  �#line 1 "/usr/lib/perl/5.14/MIME/Base64.pm"
package MIME::Base64;

use strict;
use vars qw(@ISA @EXPORT @EXPORT_OK $VERSION);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(encode_base64 decode_base64);
@EXPORT_OK = qw(encode_base64url decode_base64url encoded_base64_length decoded_base64_length);

$VERSION = '3.13';

require XSLoader;
XSLoader::load('MIME::Base64', $VERSION);

*encode = \&encode_base64;
*decode = \&decode_base64;

sub encode_base64url {
    my $e = encode_base64(shift, "");
    $e =~ s/=+\z//;
    $e =~ tr[+/][-_];
    return $e;
}

sub decode_base64url {
    my $s = shift;
    $s =~ tr[-_][+/];
    $s .= '=' while length($s) % 4;
    return decode_base64($s);
}

1;

__END__

#line 189
FILE   e04372d0/PerlIO/scalar.pm   �#line 1 "/usr/lib/perl/5.14/PerlIO/scalar.pm"
package PerlIO::scalar;
our $VERSION = '0.11_01';
require XSLoader;
XSLoader::load();
1;
__END__

#line 42
FILE   b358f7ce/Scalar/Util.pm  �#line 1 "/usr/lib/perl/5.14/Scalar/Util.pm"
# Scalar::Util.pm
#
# Copyright (c) 1997-2007 Graham Barr <gbarr@pobox.com>. All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

package Scalar::Util;

use strict;
use vars qw(@ISA @EXPORT_OK $VERSION @EXPORT_FAIL);
require Exporter;
require List::Util; # List::Util loads the XS

@ISA       = qw(Exporter);
@EXPORT_OK = qw(blessed dualvar reftype weaken isweak tainted readonly openhandle refaddr isvstring looks_like_number set_prototype);
$VERSION    = "1.23";
$VERSION   = eval $VERSION;

unless (defined &dualvar) {
  # Load Pure Perl version if XS not loaded
  require Scalar::Util::PP;
  Scalar::Util::PP->import;
  push @EXPORT_FAIL, qw(weaken isweak dualvar isvstring set_prototype);
}

sub export_fail {
  if (grep { /dualvar/ } @EXPORT_FAIL) { # no XS loaded
    my $pat = join("|", @EXPORT_FAIL);
    if (my ($err) = grep { /^($pat)$/ } @_ ) {
      require Carp;
      Carp::croak("$err is only available with the XS version of Scalar::Util");
    }
  }

  if (grep { /^(weaken|isweak)$/ } @_ ) {
    require Carp;
    Carp::croak("Weak references are not implemented in the version of perl");
  }

  if (grep { /^(isvstring)$/ } @_ ) {
    require Carp;
    Carp::croak("Vstrings are not implemented in the version of perl");
  }

  @_;
}

sub openhandle ($) {
  my $fh = shift;
  my $rt = reftype($fh) || '';

  return defined(fileno($fh)) ? $fh : undef
    if $rt eq 'IO';

  if (reftype(\$fh) eq 'GLOB') { # handle  openhandle(*DATA)
    $fh = \(my $tmp=$fh);
  }
  elsif ($rt ne 'GLOB') {
    return undef;
  }

  (tied(*$fh) or defined(fileno($fh)))
    ? $fh : undef;
}

1;

__END__

FILE   !f0c778a4/Tie/Hash/NamedCapture.pm   �#line 1 "/usr/lib/perl/5.14/Tie/Hash/NamedCapture.pm"
use strict;
package Tie::Hash::NamedCapture;

our $VERSION = "0.08";

require XSLoader;
XSLoader::load(); # This returns true, which makes require happy.

__END__

#line 50
FILE   5f358da5/attributes.pm  
�#line 1 "/usr/lib/perl/5.14/attributes.pm"
package attributes;

our $VERSION = 0.14;

@EXPORT_OK = qw(get reftype);
@EXPORT = ();
%EXPORT_TAGS = (ALL => [@EXPORT, @EXPORT_OK]);

use strict;

sub croak {
    require Carp;
    goto &Carp::croak;
}

sub carp {
    require Carp;
    goto &Carp::carp;
}

my %deprecated;
$deprecated{CODE} = qr/\A-?(locked)\z/;
$deprecated{ARRAY} = $deprecated{HASH} = $deprecated{SCALAR}
    = qr/\A-?(unique)\z/;

sub _modify_attrs_and_deprecate {
    my $svtype = shift;
    # Now that we've removed handling of locked from the XS code, we need to
    # remove it here, else it ends up in @badattrs. (If we do the deprecation in
    # XS, we can't control the warning based on *our* caller's lexical settings,
    # and the warned line is in this package)
    grep {
	$deprecated{$svtype} && /$deprecated{$svtype}/ ? do {
	    require warnings;
	    warnings::warnif('deprecated', "Attribute \"$1\" is deprecated");
	    0;
	} : 1
    } _modify_attrs(@_);
}

sub import {
    @_ > 2 && ref $_[2] or do {
	require Exporter;
	goto &Exporter::import;
    };
    my (undef,$home_stash,$svref,@attrs) = @_;

    my $svtype = uc reftype($svref);
    my $pkgmeth;
    $pkgmeth = UNIVERSAL::can($home_stash, "MODIFY_${svtype}_ATTRIBUTES")
	if defined $home_stash && $home_stash ne '';
    my @badattrs;
    if ($pkgmeth) {
	my @pkgattrs = _modify_attrs_and_deprecate($svtype, $svref, @attrs);
	@badattrs = $pkgmeth->($home_stash, $svref, @pkgattrs);
	if (!@badattrs && @pkgattrs) {
            require warnings;
	    return unless warnings::enabled('reserved');
	    @pkgattrs = grep { m/\A[[:lower:]]+(?:\z|\()/ } @pkgattrs;
	    if (@pkgattrs) {
		for my $attr (@pkgattrs) {
		    $attr =~ s/\(.+\z//s;
		}
		my $s = ((@pkgattrs == 1) ? '' : 's');
		carp "$svtype package attribute$s " .
		    "may clash with future reserved word$s: " .
		    join(' : ' , @pkgattrs);
	    }
	}
    }
    else {
	@badattrs = _modify_attrs_and_deprecate($svtype, $svref, @attrs);
    }
    if (@badattrs) {
	croak "Invalid $svtype attribute" .
	    (( @badattrs == 1 ) ? '' : 's') .
	    ": " .
	    join(' : ', @badattrs);
    }
}

sub get ($) {
    @_ == 1  && ref $_[0] or
	croak 'Usage: '.__PACKAGE__.'::get $ref';
    my $svref = shift;
    my $svtype = uc reftype($svref);
    my $stash = _guess_stash($svref);
    $stash = caller unless defined $stash;
    my $pkgmeth;
    $pkgmeth = UNIVERSAL::can($stash, "FETCH_${svtype}_ATTRIBUTES")
	if defined $stash && $stash ne '';
    return $pkgmeth ?
		(_fetch_attrs($svref), $pkgmeth->($stash, $svref)) :
		(_fetch_attrs($svref))
	;
}

sub require_version { goto &UNIVERSAL::VERSION }

require XSLoader;
XSLoader::load();

1;
__END__
#The POD goes here

FILE   'd978f832/auto/Compress/Raw/Zlib/Zlib.so 9�ELF          >    `8      @       (3         @ 8  @                                 *     *                   �+     �+!     �+!     P      X                    �+     �+!     �+!     �      �                   �      �      �      $       $              P�td   �     �     �     4      4             Q�td                                                  R�td   �+     �+!     �+!                                   GNU [�i�B �gE�;M!��fD    �   �           s          �   A      3   ,   I       :       6   @   )                      �      9       (              1       K   '   k   t           q      �       d   M   5   i           *   V           "       a                               7       F       8       r       C   0                      2   ]   n   ^   Y   f   Q   v   �               E   D   G   P   Z   +   J   u      S               &   T   =   p       ?       �       �   <   _   j           !       H       y   \       .   x      W       g   N                                                                                  z                                             c                                         %   o   e   b   �               h           U          �      �       �   `   |          L   R              ;   m   �   �   B          ~   $   O   /   {                          -      X       l              #              
   �               [                           >       	       w           
 �3              :                     [                     $	                                          /                     �
                     *                     f
                     �                     �                                                                 2                     �                     �                      �                     �                      }	                     �                      q
                     X                     _                     C                     k                     T                                          �                     �	                     �                      m                                          e                     	                                          �
                     '                     �
                                          >
                     �                     6                     �
                     R   "                   �                      �    pJ            ~    �]            �    �~      W      �    U            l    `�      d      �    0W            h    �=            �    @�      �          
    `�            �    Pj            �    px            ^    �|      Y      �    ��      �      �    �a            �    PH            7    ��      d      ~
    ��      {           �      4      u     `9            q    ��      �      �	    @�      �      �    �_            H    f            �
    0�      �
      W    �P            �    ��      d      K
    ��      �      �    ��      �          �c                ��      
      �    �t                D            �   ��02!             �    �      B      8    �;            ?	    `�      �      v    �r            �    �L            	    �n            �    `�      9      �    @�      �      �    w      Q      )    �N                PY                
 �3              �    �A             __gmon_start__ _init _fini _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize _Jv_RegisterClasses XS_Compress__Raw__Zlib__inflateScanStream_adler32 PL_thr_key pthread_getspecific Perl_sv_newmortal Perl_sv_derived_from Perl_sv_setuv Perl_mg_set Perl_sv_2iv_flags Perl_croak Perl_croak_xs_usage XS_Compress__Raw__Zlib__inflateScanStream_crc32 XS_Compress__Raw__Zlib__inflateScanStream_getLastBufferOffset XS_Compress__Raw__Zlib__inflateScanStream_getLastBlockOffset XS_Compress__Raw__Zlib__inflateScanStream_uncompressedBytes XS_Compress__Raw__Zlib__inflateScanStream_compressedBytes XS_Compress__Raw__Zlib__inflateScanStream_inflateCount XS_Compress__Raw__Zlib__inflateScanStream_getEndOffset XS_Compress__Raw__Zlib__inflateStream_get_Bufsize XS_Compress__Raw__Zlib__inflateStream_total_out XS_Compress__Raw__Zlib__inflateStream_adler32 XS_Compress__Raw__Zlib__inflateStream_total_in XS_Compress__Raw__Zlib__inflateStream_dict_adler XS_Compress__Raw__Zlib__inflateStream_crc32 XS_Compress__Raw__Zlib__inflateStream_status XS_Compress__Raw__Zlib__inflateStream_uncompressedBytes XS_Compress__Raw__Zlib__inflateStream_compressedBytes XS_Compress__Raw__Zlib__inflateStream_inflateCount XS_Compress__Raw__Zlib__deflateStream_total_out XS_Compress__Raw__Zlib__deflateStream_total_in XS_Compress__Raw__Zlib__deflateStream_uncompressedBytes XS_Compress__Raw__Zlib__deflateStream_compressedBytes XS_Compress__Raw__Zlib__deflateStream_adler32 XS_Compress__Raw__Zlib__deflateStream_dict_adler XS_Compress__Raw__Zlib__deflateStream_crc32 XS_Compress__Raw__Zlib__deflateStream_status Perl_sv_setiv XS_Compress__Raw__Zlib__deflateStream_get_Bufsize XS_Compress__Raw__Zlib__deflateStream_get_Strategy XS_Compress__Raw__Zlib__deflateStream_get_Level XS_Compress__Raw__Zlib_ZLIB_VERNUM XS_Compress__Raw__Zlib__inflateStream_msg Perl_sv_setpv XS_Compress__Raw__Zlib__deflateStream_msg XS_Compress__Raw__Zlib_zlib_version zlibVersion Perl_safesysmalloc XS_Compress__Raw__Zlib__inflateScanStream_resetLastBlockByte Perl_sv_2pvbyte XS_Compress__Raw__Zlib__inflateStream_set_Append Perl_sv_2mortal Perl_sv_2bool_flags Perl_croak_nocontext Perl_newSVpv Perl_mg_get XS_Compress__Raw__Zlib_crc32 Perl_sv_2uv_flags Perl_sv_utf8_downgrade XS_Compress__Raw__Zlib_adler32 XS_Compress__Raw__Zlib__inflateScanStream_DESTROY inflateEnd Perl_safesysfree Perl_sv_free Perl_sv_free2 XS_Compress__Raw__Zlib__inflateStream_DESTROY Perl_sv_backoff Perl_sv_upgrade XS_Compress__Raw__Zlib__deflateStream_deflateTune XS_Compress__Raw__Zlib__deflateStream_DESTROY deflateEnd XS_Compress__Raw__Zlib_adler32_combine adler32_combine64 XS_Compress__Raw__Zlib_crc32_combine crc32_combine64 __errno_location strerror XS_Compress__Raw__Zlib__inflateScanStream_status Perl_sv_setnv XS_Compress__Raw__Zlib__inflateStream_inflateSync memmove XS_Compress__Raw__Zlib__inflateStream_inflate Perl_sv_pvbyten_force Perl_sv_grow inflateSetDictionary Perl_sv_utf8_upgrade_flags_grow XS_Compress__Raw__Zlib__deflateStream__deflateParams XS_Compress__Raw__Zlib__deflateStream_flush XS_Compress__Raw__Zlib__deflateStream_deflate XS_Compress__Raw__Zlib__inflateScanStream__createDeflateStream deflateInit2_ Perl_sv_setref_pv Perl_dowantarray Perl_newSViv Perl_stack_grow deflateSetDictionary deflatePrime XS_Compress__Raw__Zlib__deflateInit XS_Compress__Raw__Zlib__inflateScanStream_inflateReset XS_Compress__Raw__Zlib__inflateStream_inflateReset XS_Compress__Raw__Zlib__deflateStream_deflateReset XS_Compress__Raw__Zlib__inflateInit inflateInit2_ Perl_newSVsv XS_Compress__Raw__Zlib_constant Perl_newSVpvf_nocontext Perl_sv_2pv_flags memcmp Perl_sv_setpvn __printf_chk putchar puts XS_Compress__Raw__Zlib__inflateScanStream_DispStream XS_Compress__Raw__Zlib__inflateStream_DispStream XS_Compress__Raw__Zlib__deflateStream_DispStream XS_Compress__Raw__Zlib__inflateScanStream_scan memcpy boot_Compress__Raw__Zlib Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck Perl_newXS Perl_get_sv Perl_call_list libz.so.1 libc.so.6 _edata __bss_start _end ZLIB_1.2.0.8 ZLIB_1.2.3.3 ZLIB_1.2.2.3 GLIBC_2.3.4 GLIBC_2.2.5                                                                                                                                                                                                                       z     @   8��   �     3��   �     3��   �        �         ti	   �     ui	   �      �+!            09      �+!            �8      (2!            (2!     �-!        l           �-!        k           �-!        �           �-!        L           �-!        �            .!        \           .!                   .!        �           .!        t            .!        h           (.!        |           0.!        b           8.!        f           @.!        V           H.!        n           P.!        w           X.!        z           `.!        {           h.!                   p.!        U           x.!        c           �.!        ^           �.!        s           �.!        �           �.!        d           �.!        e           �.!        m           �.!        R           �.!        "           �.!        u           �.!        _           �.!        ~           �.!        �           �.!        M           �.!        o           �.!        �           �.!        �            /!        O           /!        N           /!                   /!        �            /!        �           (/!        `           0/!        X           8/!        W           @/!        a           H/!        p           P/!        Y           X/!        �           `/!        ]           h/!        g           p/!        Z           x/!        [           �/!        =           �/!        �           �/!        q           �/!        i           �/!        S           �/!        �           �/!        r           �/!        D           �/!        P           �/!        j           �/!        Q           �/!        y           �/!        J            0!                   0!                   0!                   0!                    0!                   (0!                   00!                   80!        	           @0!        
           H0!                   P0!        
   �@����%��  h   �0����%��  h   � ����%��  h
�  h   � ����%�  h   �����%��  h   � ����%��  h   ������%��  h    ������%��  h!   ������%��  h"   ������%��  h#   �����%��  h$   �����%��  h%   �����%��  h&   �����%��  h'   �p����%��  h(   �`����%��  h)   �P����%��  h*   �@����%��  h+   �0����%��  h,   � ����%��  h-   �����%z�  h.   � ����%r�  h/   ������%j�  h0   ������%b�  h1   ������%Z�  h2   ������%R�  h3   �����%J�  h4   �����%B�  h5   �����%:�  h6   �����%2�  h7   �p����%*�  h8   �`����%"�  h9   �P����%�  h:   �@����%�  h;   �0����%
�  h<   � ����%�  h=   �����%��  h>   � ����%��  h?   ������%��  h@   ������%��  hA   ������%��  hB   ������%��  hC   �����%��  hD   ����H��H�M�  H��t��H��Ð��������H���  H�=��  UH)�H��H��w]�H�d�  H��t�]��@ H�y�  H�=r�  UH)�H��H��H��H��?H�H��H��u]�H���  H��t�]��@ �=9�   u'H�=��   UH��tH�=�  �-����h���]��  ��fffff.�     H�=��   tH�?�  H��tUH�=��  H����]�W����R�����AVAUI��ATUSH���  �;�����;L�0�}���H�Pp�;Lc"H��H�Pp�g���H�@�;A�l$J��I)�L��H������  �@���H�@�;�@# �  �+���H���s���I�ċ;Hc�L�4�    ����H�@H���@
���L��L��H�������A�D$@t�;�����L��H��������;L�e������;H�������LpL�u []A\A]A^�@ �����;L�`����H�@H�@M�$�������    ����H�@�;H��L�h�x����   H��L�������>����;�\���L���  H�
���LpL�u []A\A]A^�f�     ������;L�`�����H�@H�@M�$�������    �����H�@�;H��L�h�����   H��L��������6����;����L�ͥ  H�
���L��L��H�������A�D$@t�;�����L��H��������;L�e������;H�������LpL�u []A\A]A^�@ �����;L�`����H�@H�@M�$�������    ����H�@�;H��L�h�x����   H��L�������>����;�\���L���  H�
���LpL�u []A\A]A^�f�     ������;L�`�����H�@H�@M�$�������    �����H�@�;H��L�h�����   H��L��������6����;����L��  H�
���L��H��������;L�e������;H�������LpL�u []A\A]A^�f�     ������;L�`�����H�@H�@M�$�������    ����H�@�;H��L�h�����   H��L��������6����;�t���L�͔  H�
�    H����t	f�  H����t� H��H���H�x�  �@��t��f�  H����@��t�fD  �    ��H���f�     AVAUI��ATUSH���  �;�7����;L�0�-���H�Pp�;Lc"H��H�Pp����H�@�;A�l$J��I)�L��H������  ����H�@Hc�H���@
���H�@�;N�$�������   H��L���+����D$�;L�e�ܢ��H�@�;J���@
���LxL�} H��[]A\A]A^A_� ����H�@H��H�@H� L�h �`��� �;�ɓ��1�L��H�������y����    �;詓��H��P  �@8t\A�D$�?���f��;艓��L��H���~��������f�     �;H�L$�d���1�H��L��跓��H�L$H���o���f.�     �;�9����   L��H���������u�H�=�j  1�跔���;����L�Ic  H�
  �e����;H�@Mc�L�|$N�l��M���L�|$H�@�;J�l��8���H�L$H�@H�T$H��H��H�T$0�@
���H�L$H�@�;L�$������H��H��L�������;����H�T$H�@�;H�ЁH "  �ƌ���;H��輌��H�@HD$0H�E H��X[]A\A]A^A_Ë;虌��1�H��H�����������    �;�L$H�t$�p���H�t$1�H��������L$H���=���D  ��A�������	�E���   �R���A���������C����H�L$(�A�    ������;����H��P  �@8�   H�T$(�B%  )=   �����H�T$(H�H�@H�D$HH�B���� 軋��H�L$H�@�;H��L�p裋���   H��L���ӊ��A��I��������;����L�d$H�@I��J�<� ������;�`���H�@�;J���@
E�F8E�����;A���   苅���;L�p者��M�H���ň��I��;�k����;H�@L�4��\����A*�H��L��L�5/P  襄��E��tD���X���I�Ƌ;�.���H�@�;L�$�����L��H��L���A����;�
���H�@�;H��H "  �����;H������LhL�m H��[]A\A]A^A_� �˄��H�@J��H� D�` �����    諄��H�@�;N�,�蜄���   H��L������H�D$�����f��{���H�@�;N�,��l����   H��L��蜃���D$���� �K���H�@�;N�,��<����   H��L���l���A������@ ����H�@�;H��L�p�����   H��L���8���I��������;����L�BV  H�
z��D�D$E��tD������H�ŋ;�z��H�@�;N�,��z��H��H��L���z���;�jz��H�@�;J���H "  �Tz���;H���Jz��H�@HD$(H�E H��8[]A\A]A^A_�fD  �#z��H�@�;J��L�h�z���   H��L���@y��I�������     H�E�p����    H�L$H�A�����f��;��y��H��P  �@8��   H�L$�A���� �;�y��H��P  �@8������;�y���   H��H���Iy���������H�=�S  �{��D  A�W I�wI��z��I�G�m���fD  I�H���$y��A�?I�G�F����     1�E1�����fD  �;D�D$�y��H��H����z��D�D$������    �;��x��H�t$�   H���x����tQH�T$�B�����;�x��L�K  H�
p��H�@�;J���@
q���;H���m��H�	@  L��H��H���l���;I���m��H�P L)�H���p  �;M�l$I�l$�om��H�@�;�@"�  �Zm��H�@�@"��<�����}  �;�;m��H�(H��8[]A\A]A^A_�f�     �m��H�@H��H� �@ �D$$�����@ ��l��H�@�;N�,���l���   H��L���ll��H�D$(�����f���l��H�@�;N�<��l���   H��L����k��A������@ �l��H�@�;N�4��l���   H��L���k��A���4���@ �kl��H�@�;N�,��\l���   H��L���k���D$����� �;l��H�@�;N�,��,l���   H��L���\k���D$ �j��� �l��H�@�;N�,���k���   H��L���,k���D$���� ��k��H����m��������������;L�-�6  �k��Ic�H���n���;I���k��L��H���m���;I���k���A*�L��H����j��E����   �;�mk��L��H��L���k��A�L$ "  �;�Ok��H�@ H)�H����   L�eH�������A��fD  L��E1��]m���O����     �;�	k��L��L��   H���j��I���n���fD  H�u������    �;��j��H��P  �@8tdH�E H�P�E����@ A����������D  �;�j��H��H��   H���&j��H���@���fD  D������I��������     �;�Yj���   H��H���j����u�H�=�E  1���k���;�0j��H��E  L��H���k��fffff.�     AVAUI��ATUSH�fc  �;��i���;L�0��i��H�Pp�;Lc"H��H�Pp��i��H�@�;A�l$J��I)�L��H������  �i��H�@Hc�L�4�    H���@
���I�ŋ;��c��H�@�;L�$���c��L��H��L����c���;�c��H�@�;H��H "  �c���;H���c��LpL�u []A\A]A^� �c��H�@H��H�@H� L�h I�}�c����A������A���   A���   L��A�u �����������;�6c��L��5  H�
   H�5�#  �����    L��A�   ��Z��������������D  �;�Z��A�D$<U�{  <X��  <F�����H�5E#  L��	   �Z����L��H�=�6  ���������A�D$<R��  <S�����H�5�"  �   L��A�   �@Z�����`����i��� �;�Y��A�D$��D<�N���H��9  ��Hc�H���D  �   H�5k"  �����    H�5R"  �   L��A�   ��Y����������������   H�5 "  �c���H�5�"  �   L���Y����������;��X��H�@ L)�H���;��X��L��L��   H���eX��I�ŋ;�X���;H@  I�E�X��H��!  �   L��H���3[��A�G@������;�X��L��H���vZ��������;�iX��L��L��   H����W��I���.���fD  H�5o"  �   L��I��������X��������������H�5)"  �   L��I�������X���������������     �   H�5,!  �3����    �   H�5+"  �����    H�5U!  �   L��I�������EX�����e����n����     �	   H�5�   ������    H�5�   �
   L��A�   ��W���������'���H�5�   �   L��A�   ��W���������� ����   H�5X   �����H�5E   �   L��A�   �W���������������   H�5   �����   H�5�  �����   H�5�  ����H�5�   �   L��I�������DW�����d����m����   H�5f   �F����   H�5H   �5����   H�5*   ������   H�5   ���� H�5�  �	   L��A�   ��V��������������f�     H�5�  �
   L��E1��V��������������@ H�5�  �   L��I�������}V��������������;��U��H��  L��H���V���    UH��S1�H��D  �T H�5L   1��   H����W��H��u�H��[]��    ATH��1�UH��H�5-   SH���   �W��H��tH�5#   H��   1��W���
   �T��H���  H�SH�5   �   1��[W��H�SXH�5   �   1��DW��H�S`H�5    �   1��-W��H�ShH�5$   1��   �W��H�SHH����  H�5   �   1���V��H�SH�57   1��   ��V��H�{ tH�57   �   1���V��H�{�����
   ��S��H�S0H�5   1��   �V��H�{0 tH�5�  �   1��V��H�{0�x����
   H�-�  L�%�  �S���S H�5�  �   1��JV���S8H�5�  �   1��4V��H�S(H�5�  �   1��V��H�S@H�5�  �   1��V��H�SxH�5�  �   1���U��H���   H�5�  �   1���U��H���   H�5�  �   1��U��H���   H�5�  �   1��U�����   H�5�  �   1��U���SH�5�  �   1��qU���SH�5�  �   1��[U���H�5�  �   1��FU���H��H�5�  �   ID�1��)U���H��H�5�  �   ID�1��U���H��H�5�  �   ID�1���T���H��H�5�  �   ID�1���T���H��H�5�  �   ID�1��T��H���   H�5�  �   1��T��[]A\�
   �Q��D  H�=�  ��Q�������    []A\H�=�  ��Q��AVAUI��ATUSH�fK  �;��Q���;L�0��Q��H�Pp�;Lc"H��H�Pp��Q��H�@�;A�l$J��I)�L��H��A�ă�����  �Q��H�@Hc�H���@
Q��H�@�;J���x��   ��P��H�@J���@ �  ����u[1�L���a����;��P���;I����P��H�@H�D��I�$[]A\A]A^�f.�     �P��H�@H��H�@H� L�h �h��� �;�yP��H�@�;J���@%   =   t0�[P��H�@�;N�$��LP��1�H��L���P��H���^����    �+P��H�@J��H�p�A���f.�     �P��H�@J��H�@�@ �  �������;��O��L�2  H�
��0@�2H��J�L�� ���L9�IG�H9�u�A��D�2u�AǇ�    �  �z����    �;��C��L��H����E������f�     E1�I�W(E���   I���   I�$H�RI��   H)�I���   ����D  I�W(E���   A�w I���   I�$H�@H)�I��   A���H��������A�G �f.�     �;�YC���   L��H���C��������H�=:!  1���D�� �;�)C��1�H��L���|C��H�������C��H�@�;N�$�� C���   H��L���@B���M���E�u I�u��  L���C��E���  ����f�     ��)�9�r��fD  ���)�9�v����3������,���E���  I�}��  L����D��E�u �_����;�oB��L��  H�
  H�*   H�5S
  H��1��C���DB��H��  L��H���2C��f�AVAUATUSH��;  �;�B���;H�(�B��H�Pp�;Lc*H��H�Pp��A��H�@�;E�eJ��H)���A��H�@Icԋ;L�,�    H��L�4���A��H��  �   H��L���C���;�A��H�
  H�5�  H���>���;��<��H��6  H�
  H�5  H���>���;��<��H�96  H�
  H�5�  H���s>���;�<��H��6  H�
  H�5O  H���O>���;�<��H��5  H�
  H�5�  H���+>���;�d<��H�}6  H�
  H�5�  H���>���;�@<��H�	7  H�
  H�5�
  H���<���;�H:��H��4  H�
  H����;���;�$:��H�-4  H�
     stream pointer is NULL     stream           0x%p
            zalloc    0x%p
            zfree     0x%p
            opaque    0x%p
            msg       %s
            msg                   next_in   0x%p  =>            next_out  0x%p            avail_in  %lu
            avail_out %lu
            total_in  %ld
            total_out %ld
            adler     %ld
     bufsize          %ld
     dictionary       0x%p
     dict_adler       0x%ld
     zip_mode         %d
     crc32            0x%x
     adler32          0x%x
     flags            0x%x
            APPEND    %s
            CRC32     %s
            ADLER32   %s
            CONSUME   %s
            LIMIT     %s
     window           0x%p
 s, message=NULL s, buf, out=NULL, eof=FALSE inflateScan v5.14.0 2.033 Zlib.c Compress::Raw::Zlib::constant Compress::Raw::Zlib::adler32 Compress::Raw::Zlib::crc32     Compress::Raw::Zlib::inflateScanStream  Compress::Raw::Zlib::inflateScanStream::adler32 Compress::Raw::Zlib::inflateScanStream::crc32   Compress::Raw::Zlib::inflateScanStream::getLastBufferOffset     Compress::Raw::Zlib::inflateScanStream::getLastBlockOffset      Compress::Raw::Zlib::inflateScanStream::uncompressedBytes       Compress::Raw::Zlib::inflateScanStream::compressedBytes Compress::Raw::Zlib::inflateScanStream::inflateCount    Compress::Raw::Zlib::inflateScanStream::getEndOffset    Compress::Raw::Zlib::inflateStream      Compress::Raw::Zlib::inflateStream::get_Bufsize Compress::Raw::Zlib::inflateStream::total_out   Compress::Raw::Zlib::inflateStream::adler32     Compress::Raw::Zlib::inflateStream::total_in    Compress::Raw::Zlib::inflateStream::dict_adler  Compress::Raw::Zlib::inflateStream::crc32       Compress::Raw::Zlib::inflateStream::status      Compress::Raw::Zlib::inflateStream::uncompressedBytes   Compress::Raw::Zlib::inflateStream::compressedBytes     Compress::Raw::Zlib::inflateStream::inflateCount        Compress::Raw::Zlib::deflateStream      Compress::Raw::Zlib::deflateStream::total_out   Compress::Raw::Zlib::deflateStream::total_in    Compress::Raw::Zlib::deflateStream::uncompressedBytes   Compress::Raw::Zlib::deflateStream::compressedBytes     Compress::Raw::Zlib::deflateStream::adler32     Compress::Raw::Zlib::deflateStream::dict_adler  Compress::Raw::Zlib::deflateStream::crc32       Compress::Raw::Zlib::deflateStream::status      Compress::Raw::Zlib::deflateStream::get_Bufsize Compress::Raw::Zlib::deflateStream::get_Strategy        Compress::Raw::Zlib::deflateStream::get_Level   Compress::Raw::Zlib::inflateStream::msg Compress::Raw::Zlib::deflateStream::msg Compress::Raw::Zlib::inflateScanStream::resetLastBlockByte      Compress::Raw::Zlib::inflateStream::set_Append  %s: buffer parameter is not a SCALAR reference  %s: buffer parameter is a reference to a reference      Wide character in Compress::Raw::Zlib::crc32    Wide character in Compress::Raw::Zlib::adler32  Compress::Raw::Zlib::inflateScanStream::DESTROY Compress::Raw::Zlib::inflateStream::DESTROY     %s: buffer parameter is read-only       s, good_length, max_lazy, nice_length, max_chain        Compress::Raw::Zlib::deflateStream::deflateTune Compress::Raw::Zlib::deflateStream::DESTROY     Compress::Raw::Zlib::inflateScanStream::status  Compress::Raw::Zlib::inflateStream::inflateSync Wide character in Compress::Raw::Zlib::Inflate::inflateSync     Compress::Raw::Zlib::inflateStream::inflate     Compress::Raw::Zlib::Inflate::inflate input parameter cannot be read-only when ConsumeInput is specified        Wide character in Compress::Raw::Zlib::Inflate::inflate input parameter Wide character in Compress::Raw::Zlib::Inflate::inflate output parameter        s, flags, level, strategy, bufsize      Compress::Raw::Zlib::deflateStream::_deflateParams      Compress::Raw::Zlib::deflateStream::flush       Wide character in Compress::Raw::Zlib::Deflate::flush input parameter   Compress::Raw::Zlib::deflateStream::deflate     Wide character in Compress::Raw::Zlib::Deflate::deflate input parameter Wide character in Compress::Raw::Zlib::Deflate::deflate output parameter        inf_s, flags, level, method, windowBits, memLevel, strategy, bufsize    Compress::Raw::Zlib::inflateScanStream::_createDeflateStream    flags, level, method, windowBits, memLevel, strategy, bufsize, dictionary       Wide character in Compress::Raw::Zlib::Deflate::new dicrionary parameter        Compress::Raw::Zlib::inflateScanStream::inflateReset    Compress::Raw::Zlib::inflateStream::inflateReset        Compress::Raw::Zlib::deflateStream::deflateReset        flags, windowBits, bufsize, dictionary  Your vendor has not defined Zlib macro %s, used Unexpected return type %d while processing Zlib macro %s, used  Compress::Raw::Zlib::inflateScanStream::DispStream      Compress::Raw::Zlib::inflateStream::DispStream  Compress::Raw::Zlib::deflateStream::DispStream  Compress::Raw::Zlib::inflateScanStream::scan    Wide character in Compress::Raw::Zlib::InflateScan::scan input parameter        Compress::Raw::Zlib::zlib_version       Compress::Raw::Zlib::ZLIB_VERNUM        Compress::Raw::Zlib::crc32_combine      Compress::Raw::Zlib::adler32_combine    Compress::Raw::Zlib::_deflateInit       Compress::Raw::Zlib::_inflateScanInit   Compress::Raw::Zlib::_inflateInit       Compress::Raw::Zlib needs zlib version 1.x
     Compress::Raw::Zlib::gzip_os_code        ���������������p��� �������p���@���������������������`�������������������������������������r���a���9�������������������������������������������������������~���~���~�������~�������~���~���~���~���~���~���~���W���        need dictionary                 stream end                                                      file error                      stream error                    data error                      insufficient memory             buffer error                    incompatible version                                            ;4  E    ��P  �"��x  �$���  �&���  �(��8  +��x  0-���  P/���  p1��8  �3��x  �5���  �7���  �9��8  <��x  0>���  P@���  pB��8  �D��x  �F���  �H���  �J��8  M��x  0O���  PQ���  pS��8  �U��x  �W���  �Y���  �[��8	  ^��x	  0`���	  �a���	  �c�� 
  �e��`
  0g���
  �g���
  0j���
  �m��(  �n��P  �q���  �t���  �v��  �x��@  �z��h  `~���  @����  ����0
(A BBBE  <   �   �!��   B�B�E �A(�A0�a
(A BBBE  <   �   �#��   B�B�E �A(�A0�d
(A BBBJ  <     �%��)   B�B�E �A(�A0�t
(A BBBJ  <   D  �'��   B�B�E �A(�A0�d
(A BBBJ  <   �  p)��   B�B�E �A(�A0�d
(A BBBJ  <   �  P+��   B�B�E �A(�A0�d
(A BBBJ  <     0-��   B�B�E �A(�A0�d
(A BBBJ  <   D  /��   B�B�E �A(�A0�d
(A BBBJ  <   �  �0��   B�B�E �A(�A0�a
(A BBBE  <   �  �2��   B�B�E �A(�A0�a
(A BBBE  <     �4��   B�B�E �A(�A0�a
(A BBBE  <   D  �6��   B�B�E �A(�A0�d
(A BBBJ  <   �  p8��   B�B�E �A(�A0�a
(A BBBE  <   �  P:��   B�B�E �A(�A0�d
(A BBBJ  <     0<��   B�B�E �A(�A0�d
(A BBBJ  <   D  >��   B�B�E �A(�A0�d
(A BBBJ  <   �  �?��   B�B�E �A(�A0�d
(A BBBJ  <   �  �A��   B�B�E �A(�A0�a
(A BBBE  <     �C��   B�B�E �A(�A0�a
(A BBBE  <   D  �E��   B�B�E �A(�A0�d
(A BBBJ  <   �  pG��   B�B�E �A(�A0�d
(A BBBJ  <   �  PI��   B�B�E �A(�A0�a
(A BBBE  <     0K��   B�B�E �A(�A0�d
(A BBBJ  <   D  M��   B�B�E �A(�A0�a
(A BBBE  <   �  �N��   B�B�E �A(�A0�d
(A BBBJ  <   �  �P��   B�B�E �A(�A0�d
(A BBBJ  <     �R��   B�B�E �A(�A0�d
(A BBBJ  <   D  �T��   B�B�E �A(�A0�d
(A BBBJ  $   �  pV��Q   ]0������
H   <   �  �W��   B�B�E �A(�A0�a
(A BBBE  <   �  �Y��   B�B�E �A(�A0�a
(A BBBE  $   ,  h[��Y   ]0������
J      T  �\���    D[
A     <   t   ]��W   B�B�E �A(�A0�=
(A BBBA  <   �  @_��B   B�B�E �A(�A0��
(A BBBG  $   �  Pb��>   J��L ��
Af
JL   	  hc���   B�B�B �E(�A0�A8�DP�
8A0A(B BBBA    L   l	  �e���   B�B�B �E(�A0�A8�DP�
8A0A(B BBBA    $   �	  �h���   T����L0�:
F $   �	  `j���   T����L0�:
F $   
  8l��   J��M��L0��
K L   4
   n���   B�B�B �E(�A0�A8�DPn
8A0A(B BBBG    $   �
  �q���   T����L0�$
D L   �
  Xs��{   B�B�B �E(�A0�A8�DP�
8A0A(B BBBD    L   �
  �u��{   B�B�B �E(�A0�A8�DP�
8A0A(B BBBD       L  �w��=    H�f
BF <   l  �w��   B�B�E �A(�A0��
(A BBBE  L   �  �y���   B�B�B �E(�A0�A8�DPq
8A0A(B BBBD    L   �  }���
   B�B�B �E(�A0�A8�D�
8A0A(B BBBA   L   L  ����4   B�B�B �E(�A0�A8�DP�
8A0A(B BBBD    L   �  ����9   B�B�E �B(�A0�A8�DpI
8A0A(B BBBD    L   �  �����   B�B�B �E(�A0�A8�Dp
8A0A(B BBBG    ,   <
AAH     L   l
8A0A(B BBBF    L   �
8A0A(B BBBJ    <     ȣ��W   B�B�E �A(�A0��
(A BBBD  <   L  ���W   B�B�E �A(�A0��
(A BBBD  <   �  ���W   B�B�E �A(�A0��
(A BBBD  L   �  (����   B�E�B �B(�A0�A8�D`M
8A0A(B BBBH    ,     ����Y   T����QP��
D       $   L  ���9    A�D�F kAA 4   t   ���`   B�F�K �
ABOYAB <   �  (���d   B�B�E �A(�A0�S
(A BBBK  <   �  X���d   B�B�E �A(�A0�S
(A BBBK  <   ,  ����d   B�B�E �A(�A0�S
(A BBBK  L   l  �����   B�B�B �E(�A0�A8�D`=
8A0A(B BBBH    <   �  ����
   B�B�B �A(�A0��	
(A BBBA                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  09      �8                     z             �             �3      
       �                           �/!            x                           p-             �&             x      	              ���o    �&      ���o           ���o    f%      ���o                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           �+!                     4      &4      64      F4      V4      f4      v4      �4      �4      �4      �4      �4      �4      �4      �4      5      5      &5      65      F5      V5      f5      v5      �5      �5      �5      �5      �5      �5      �5      �5      6      6      &6      66      F6      V6      f6      v6      �6      �6      �6      �6      �6      �6      �6      �6      7      7      &7      67      F7      V7      f7      v7      �7      �7      �7      �7      �7      �7      �7      �7      8      8      &8      68      F8      V8      (2!     Zlib.so ��� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                  �      �      $                              "             �      �      L                              ���o       @      @      �                            (             0      0      P
# Index created by AutoSplit for ../../lib/Compress/Raw/Zlib.pm
#    (file acts as timestamp)
1;
FILE   e6d5462e/auto/Cwd/Cwd.so  8�ELF          >    p      @       �1          @ 8  @                                 �      �                    �-      �-      �-                                 �-      �-      �-      �      �                   �      �      �      $       $              P�td   �      �      �      4       4              Q�td                                                  R�td   �-      �-      �-      H      H                      GNU 3W�A��Z��'�\�bB�Kf�    %   )             
                       %               !                 (                       	                                           ��` �H    "   %   BE���|*���qX���n������{+���X                             
 �
                     �                      �                                           8                       R   "                   '                     )   ���0              <   ���0              �           7      0   ���0                  
 �
           80                    @0                    H0         
"  h   ������%"  h   �����%�!  h   �����%�!  h   �����%�!  h   �����%�!  h   �p����%�!  h   �`����%�!  h	   �P����%�!  h
   �@����%�!  h   �0����%�!  h   � ����%�!  h
  t�C
8A0A(B BBBE  $   �   ����7   X0�����
G     $   �   ����v   T����L0��
A  <   �    ����   B�B�B �A(�A0�}(A BBB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     @                                         �
       c                           �/             X                           h             H
                    	              ���o    
      ���o           ���o    �	      ���o                                                                                                                                                                   �-                      �
      
      @                            T             H
      H
                                  ^             h      h      X                          h             �
   8   1              E                   %   F   ?      C   +             
 �              *                     �                                           �                     �                                                                 |                      �                      �                     �                      t                     �                     �                     u                      �                      �                     �                                             =                     2                     a                     Q                     U                                          
 �                  `s      �       __gmon_start__ _init _fini _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize _Jv_RegisterClasses memcpy __stack_chk_fail __memcpy_chk __ctype_b_loc PL_thr_key pthread_getspecific Perl_PerlIO_eof PerlIO_getc strcmp strtoul XS_Digest__SHA_sharewind Perl_sv_derived_from Perl_sv_2iv_flags Perl_croak Perl_croak_xs_usage Perl_safesyscalloc XS_Digest__SHA_shaopen Perl_sv_newmortal Perl_sv_setref_pv XS_Digest__SHA_add Perl_sv_2pv_flags XS_Digest__SHA_shawrite Perl_sv_setuv Perl_mg_set Perl_sv_2uv_flags shafinish shadigest shahex __sprintf_chk shabase64 strcat shadsize XS_Digest__SHA_digest Perl_newSVpv Perl_sv_2mortal shaalg XS_Digest__SHA_hashsize Perl_newSViv Perl_safesysmalloc XS_Digest__SHA_shadup Perl_PerlIO_stdout PerlIO_printf Perl_PerlIO_close PerlIO_open XS_Digest__SHA_shadump Perl_sv_setiv Perl_safesysfree XS_Digest__SHA_sha1 XS_Digest__SHA_shaclose Perl_PerlIO_stdin XS_Digest__SHA_shaload hmacopen hmacwrite hmacfinish hmacdigest hmachex hmacbase64 hmacclose XS_Digest__SHA_hmac_sha1 boot_Digest__SHA Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck Perl_newXS_flags Perl_call_list libc.so.6 _edata __bss_start _end GLIBC_2.3 GLIBC_2.3.4 GLIBC_2.2.5 GLIBC_2.4                                                                                                                          d         ii
           p�         >           x�                    ��         ?           ��         
�  h   �`����%�  h	   �P����%��  h
   �@����%�  h   �0����%�  h   � ����%�  h
�  h(   �`����%�  h)   �P����%��  h*   �@����%�  h+   �0����%�  h,   � ����%�  h-   �����%ڣ  h.   � ����%ң  h/   ������%ʣ  h0   ������%£  h1   ������%��  h2   ������%��  h3   �����%��  h4   �����%��  h5   �����%��  h6   �����%��  h7   �p����%��  h8   �`����%��  h9   �P���H��H�E�  H��t��H��Ð��������H��  H�=�  UH)�H��H��w]�H�̠  H��t�]��@ H���  H�=��  UH)�H��H��H��H��?H�H��H��u]�H���  H��t�]��@ �=y�   u'H�=�   UH��tH�=�  �
���n��1�D1�A��A֋T$�E�D1�3T$�D1���D�����nD��1�1���D�E��A��AċD$�3D$�3D$�1���D�����n��D1�D1�A��D�E��A��D�D�|$�D3|$�E1�A1�A��G��=���nD�|$�A��A��D�l$�E��A1�E1�Dl$�A��E�D�|$�D3|$�E1�A1�A��B��=���nD�|$�E��A���l$�D��D1�1�l$���D�D�|$�D3|$�E1�A1�A��G��>���nD�|$�A��A��D�t$�A��E1�E1�Dt$�A��E�D�|$�D3|$�E1�D�|$�D�|$�D1|$��D$�D�|$�G��<���nE��D�d$�E��A1�A1�Dd$�A����E�D�|$�D3|$�A1�D�|$�D�|$�D1|$��D$�D�|$�B��;���nE��A���\$���D1�D1�\$�A��D�D�|$�D3|$�A1�D�|$�D�|$�D1|$��D$�D�|$�G��=���nA��A��D�l$�E��A1�E1�Dl$�A��E�D�|$�E1�A1�D�|$�D�|$�D1|$��D$�D�|$�B��=���nE��A���l$�D��D1�1�l$�D�D�|$���E1�A1�D�|$�D�|$�D1|$��D$�D�|$�G��>���nA��A��D�t$�A��E1�E1�Dt$�A��E�E��A1�E1�D3|$�E��D3|$�A1�D�L$�A1���D�L$�A��G��<���nE�E��A��E�E��E1�D3d$�A��D3d$�E1�E1�A��A��B��#���nA�D����A�D1L$�D�L$�D1L$��D$�D�L$�C��
��bʉ�D�L$�D1�D�L$�1���D�A��A��E1�D�D�D$�E1�A��A��A1�G��:��b�A1�D�T$�D1T$�D�|$���D�|$�E�D1|$�A���D$�A��E�D�D$�F�� ��bʉ�E��1�A��1���D�F� �D$�E��1�3D$�3D$���D����bʉ�1�D1�A1�D3l$�D3l$�D1�3l$�A��3l$�D�A��D1�3\$�F�$A��B��)��b�D����1�D��*��b�1�D1�A�����D��D����D1��D1�A����D���D�
D��A����b�D1�1����D�����D3\$�D3t$�D3t$���D1�D1�A��E1�E1�A1�A��A��G����b�G��4��b�D�A��A��D�E��A1�A1���E�A��A��E�D�T$�D3T$�D3T$�A1�A��F����bʉ�D1�1���D�E��A��A�t$�3t$�3t$�D1���E��0��b�A��A1�E1�A��E�E��A��E�D�|$�D3|$�A1�D��E1�1�A��D1�A��B��9��b��D����ȋL$�3L$�D1�D�l$�D3l$�D1���D��
��b�D��D1�A1�D1�A1�A��A��D�D��A��G��)��b�D1�A��1�D�D���A��A��D�D�L$�D3L$�A1�E1�D�|$�D3|$�A��G����b�A��D�d$�E1�D3d$�E1�A1���A1�Eщ�A��A��1�A��G��8��b�1�E�E1�D�WD�E1�E��A��A����D�G��"��b�A��D�A��A��A1�E1�A�E�A��D�GO[]DOwW �OA\A]A^D�O�w�W A_�fD  AWAVAUATUSH��0H�|$�H�L$�H�~@@ ��V����	��V	��VH����	ЉH��H9�u�H�|$�D�d$�D�l$�D�t$�D�|$��|$�H�|$؋t$�����|$�H�|$؋�|$�H�|$؋�|$�H�|$؋ �|$�H�|$؋D$��T$��$����1ЋT$��|$�H�|$�D�T$����(1ЋT$�T$�#T$��|$�H�|$�D�D$��,G��(�D7qD�D$�B��'�/�B�|$�C��2������D$�3D$�#D$�3D$���D$�#D$�	D$���1��t$���
1�ЋT$�3T$��L$�A	�!�3T$�����Aщ���1����1��A�D#D$��T$���!�A	Љ���1����
1�AЋT$�E�DL$�E��1�A��D!�3T$�D�����D����1�D����1�D��	�#t$��D��!�	�D����D1�E��A��
D1�֋T$��|$���F��:�۵�D��1���!�A��1�A��AӉ���D1�A��A��D1�A��A�E	�D!�A!�A	҉���1ډ���
1ڋ\$�D�D�D\$�D��[�V9����D1�D!�D��D1���A�D����1�D����1ى�A�	��D!�!���	ˉ���1����
1��D�AD$�D�Ӊ�����E����YD��1�D!�1�A�D����1�D����1؉�A�	Ӊ�!�!�	É���1����
1�؋$D�E���D����?�D��D��D1�����D!�D1�A�D����1�D����1߉�D�	�A��A!�!�D	�A��A��A1����
A1�A�A���t$��D����E��3�^�D��D1�!�D1�A����1މ���1�D��A�	�D��!�!���	�D����1�D����
1��D�AӋT$D�ۉ�����E����؉�D1�D!�D1�A�D����1�D����1ډ�A�D	É�D!�!�	Ӊ���1����
1��D�AʋL$D�Ӊ�E��	[�D��1�����D!�1�A�D����1�D����1ى�A�	��!�D!�	ˉ���1����
1�ً\$D�A�D��D1؉�D!ȍ���1$D��D1����D����1�D����1؉��	Ӊ�!�!���	É���1����
1���D�D�D$����C���}UE��A��E1�A��A!�E1�D�A��A��E1�A��A��E1�A��D�A	�A��A!�A!�E	�A��A��A1؉���
A1�E�D�\$A����D1�D��!�G��t]�rA��D1�A����A����D1�A��A��D1�E��A�A	�D��!�A!�A	�D����1�D����
1�D�D�AҋT$E�Ӊ�A��E����ހ��1�D!�1�A�D����D1�E��A��D1�A��A�E	É�A!�D!���A	Ӊ���1ډ���
1�D�D�AɋL$ E�ˉ�A�������ܛD��1�D!�1��D����D1�E��A��D1�A���A	��!�E!�A	ˉ���1ى���
1ً\$$D���D��D1Ѝ�t��A��!�A����D1���ŉ���D1�A��A��D1�A���A	Ӊ�!�A!�A	É���1؉���
1؋\$ D�D�\$�D�D�D$ ��E�A��A��A1؋\$ ��
A1�D��E�E����A��A1�D����A1�A��E�A��C���i��A��A��E1�A!�E1�D�A��A��E1�A��A��E1�A��D�A	�A��A!�A!�E	�A��A��E1�A��A��
E1�D�d$$E�D�\$A��t$$A��E�E����D1�D�d$$A��
D1�E��A�D��A����D1�E��A��A��D1�A��D�A��E��1�G��A��A1�A!�A1�E�A��A��E1�A��A��E1�E��E�A	�E��A!�A!�E	�E��A��E1�E��A��
E1�E��E�A��D�d$E�A�D����D1�E��E�A��E��D1�E��A�D����A��A��D1�E��D|$A��
D1�E��D�A��D��Ɲ���1�D!�1�A�D����D1�E��A��D1�E��A�E	�D��D!�A!�A	�D����D1�E��A��
D1�D�D�l$�D�A̋L$�A��A����D1�D�l$�A��D1�A��A��Aω�A����D1�A��A��
D1�E��A�D��A��1�B��=̡$D!�1��D����D1�E��A��D1�A���E	͉�D!�E!�A	͉���D1�A��A��
D1�D�t$�D�D�l$Dl$��ŋD$�A����D1�D�t$�A��D1�A��Aŉ�A����D1�A��A��
D1�A��D�A��A���D$���o,�-D��D1�A��!�D1�É���D1�A��A��D1�A���A	���!�E!�A	ŉ���D1�A��A��
D1�D�4$D�D�l$ Dl$��D�D�$A��A��E1�D�4$A��E1�E��E�E��A��A��E1�E��A��
E1�A��E�A��A��D�T$�G����tJA��E1�A��A!�E1�E�A��A��E1�A��A��E1�A��E�A	�A��A!�A!�E	�A��A��E1�A��A��
E1�D�t$E�D�l$$E�E�D�L$A��D,$A��E1�D�t$A��E1�D�t$�E�D�L$�A��A��E1�D�t$�A��
E1�E��E�E��A��D�L$�G��ܩ�\A��A1�A��E!�A1�E�E��A��E1�E��A��E1�E��E�A	�E��A!�A!�E	�E��A��E1�E��A��
E1�D�t$�E�D�l$E�A��|$A��A����A1��|$��A1��|$�Dl$��D1�D�t$�E�A��
D1�E��D�E��A���|$Ѝ�=ڈ�vD��1�A��D!�1��D����D1�E��A��D1�E���E	�D��D!�A!�A	�D����D1�E��A��
D1�D�t$�D�D�l$�͋L$A��A����A1͋L$��A1͋L$�Dl$��D1�D�t$�A�A��
D1�A��D�A��L$ԍ�RQ>�D��D1�A��!�D1�ˉ���D1�A��A��D1�A���E	͉�D!�E!�A	͉���A��D1�A��A��
D1�D�t$�D�D�l$�ËD$A��A����A1ŋD$��A1ŋD$�Dl$��D1�D�t$�A�A��
D1�A��D�A�݉D$�E��m�1���D1�A��!�D1�AÉ���D1�A��A��D1�A��A�A	���!�E!�A	ŉ�A����D1�A��A��
D1�D�t$�D�D�l$D�E�D�T$A��A��A��E1�D�T$A��E1�D�T$�Dl$A��E1�D�t$�E�A��
E1�A��E�E��D�T$�G���'�A��A1�A��E!�A1�E�E��A��E1�E��A��E1�A��E�A	�A��A!�A!�A��E	�A��A��E1�A��A��
E1�D�t$�E�D�l$E�E�D�L$A��A��A��E1�D�L$A��E1�D�L$�Dl$Dl$�A��E1�D�t$�A��
E1�E��E�E��D�L$�B��
E1�D�t$�E�D�l$A���|$A��A����A1��|$��A1��|$�Dl$Dl$���D1�D�t$�A��
D1�E��D�A��|$ȍ�;���D��D1�A��!�D1������D1�A��A��A��D1�E���E	�D��D!�A!�A	�D����D1�E��A��
D1�D�t$�D�D�l$ �ˋL$ A��A����A1͋L$ ��A1͋L$�Dl$Dl$���D1�D�t$�A��
D1�A��D�A�݉L$�E��G��Չ�D1�!�D1�Aˉ���A��A��D1�A��A��D1�A��A�E	͉�D!�E!�A	͉���D1�A��A��
D1�D�t$�D�D�l$$D�AËD$$A��A����A1ŋD$$��A1ŋD$�Dl$ Dl$���D1�D�t$�A��
D1�A��D�D$�E��Qc���1�E��D!�1�A�D��A����A��D1�E��A��D1�A��A�A	���!�E!�E�A	ĉ���D1�A��A��
D1�D�t$�D�E��D�E��A��A��A��E1�E��A��E1�D�d$�Dl$$Dl$�A��E1�D�t$�A��
E1�A��E�F��%g))D��D�d$�1�E��D!�A��A��1�A�D����D1�E��A��D1�A��A�A	̉�!�A!�E�A	����D1�A��A��
D1�D�A��D�A��A��A��E1�A��A��E1�D�l$�E�D�d$�DD$�A��A��E1�D�l$�A��
E1�A��E�E��A��E1�D�d$�F��#�
�'E!�D��E1���E�E��A��A1�D����A1؉�E�	�A��A!�!�D�D	�A��A��E1�A��A��
E1�A؉�E�A����A��D1�A��A��D1�D�d$�ދ\$�t$�A����D1�D�d$�A��
D1�E��D�,D��A��D1�C��+8!.!�A��D1�A������D1�A��A��D1�E���A	�D��!�A!��A	�D����D1�E��A��
D1�D�E���D��A����A1�D����A1ۋ\$�D�D�\$�T$���A��A1ۋ\$���
A1ۉ�AӉ���D1�D�\$�G���m,M!�A��D1�A��AӉ���D1�A��A��D1�A��A�E	�D!�A!�A	҉���1ډ���
1�D�D�T$�D�AËD$���A����D1�D�T$�A��D1�E��A�D��D|$���A����D1�E��A��
D1�Aǉ�1�G��9
1؋\$�D�D�L$�D�D�T$�A��A��E1�D�T$�A��E1�DL$�D�T$���E�D�L$�A��A1ً\$���
A1ى�E���F��Ts
eD��D�L$�1�A��D�t$�!�A��1�A�����D1�A��A��D1�A��A�A	щ�!�A!�E�A	�����1߉���
1�D�D�L$�D�D�T$���A��A��E1�D�T$�A����E1�DL$�E��A��E�E��A��E1�E��A��
E1�E�D�t$�F��	�
jv��D�L$�D1�E��D!�A��D1�A�D����D1�E��A��D1�A��A�A	���!�A!�D�A	ɉ���1ى���
1�D�D�L$�D�D�T$Љ�A��A����E1�D�T$�A��E1�DL$�D�T$�A��E�D�L$�A��E1�D�T$�A��
E1�A��E�A��D�t$�D�L$�G��.�E��A1�A!�A1�E�A��A��E1�A��A��E1�A��E�A	�A��A!�A!�E	�A��A��A1ى���
A1�E�D�T$�E�D�D�\$ԉ�A����A��E1�D�\$�A��E1�DT$�D�\$�A��E�D�T$�A��E1�D�\$�A��
E1�E�D�T$�F���,r�A��E1�D��A!���E1�E�A��A��A1ډ���A1�D��E�	�E��A!�!�D	�E��A��A1�D����
A1�l$�D�D�D�T$�D�D�\$���A��A��E1�D�\$�A��E1�DT$�G�*D�T$�A��A1�l$���
A1��E���G���迢A��D�T$�A1�A��A!�A��A1�E�A��A��E1�A��A��E1�A��E�E	�A��E!�A!�E	�A��A��A1����
A1�Dߋl$�E�D�T$�E�D�\$���A��A��E1�D�\$�A��E1�DT$�D�\$�E�D�T$�A��A1�l$���
A1�D��E���F��Kf���D�T$�1�A��!�A��1�A����D1�A��A��D1�E��A�A	�D��!�E!�A	�D����1�D��D���
1�l$�D�D�T$�D�D�\$���A��A��E	�A��A!�E1�D�\$�A��E1�DT$�G�:D�T$�A��A1�l$���
A1�E�A��D�T$�F��p�K�1�A��!�1�A҉���D1�A��A��D1�A��A҉�D!�A	ԉ���A��E�D1�A��A��
D1�D�\$�AԋT$�E�D�T$�A����A��D1�D�T$�A��D1�T$�D�T$�AҋT$���D1�D�\$�A��
D1�E��D�D���QlǉȉT$�1�D��D!���1�A�D����1�D����1�D��A�	�D��!�D!�	�D��A����D1�E��A��
D1�D�\$�D$�D�Aڋ\$�A����D1�D�\$���A��D1�D$�D�\$�AËD$���1؋\$���
1؉�D�E��D	�D$ȍ���D��1�A��D!�1��D����D1�E��A��D1�A��ǉ�!�D!�A��A�	É���D1�A��A��
D1�D�\$�ËD$���|$�A������1��|$���1�D$̋|$�ǋD$���D1�D�\$�A��
D1���߉D$�D��$��D��D1�D��D!���D1�A�D����1�D����1ȉ�A�	׉�!�D!���	ǉ���1ȉ���
1ȋL$�ǋD$�D�A��t$�����1ȋL$�����1�D$��L$���D$���1��t$���
1����D��D$�A���5�D��D1���D�L$�D!�D1��D����1�D����	�A��1�!։�ŉ���!�	Ɖ���1ȉ���
1ȋL$�ƋD$��D�D�d$�����1ȋL$���1�D$��L$���D$���D1�D�L$�A��
D1�A��ȉ�D$�E��p�jD��D1�!�D1�A�����A��1ȉ���1ȉ�A�	���!�!�	�����D1�A��A��
D1�D�L$��D��D�A�D������A��1�D����1�D$��T$�D$���D1�D�L$�A��
D1��D�҉D$�E�� ����D1�A��D!�D1�A�D������A��1�D����1Љ�A�	��!�!�	���D1�A��A��
D1�D�D$�D$�D�A�A��E�ˉ���D1�D�D$�A��D1�D�D$�AŋD$�Dl$�A����D1�D�D$�A��
D1�A�D��1�G��.l7D!�A����1�A�D����D1�E��A��D1�A��A�A	ˉ�!�A!�A	É���1؉���
1�D�E��D�A�D��A����D��D1�E��A��D1�D�\$�A��|$�Dd$�A����D1�D�\$�A��
D1�A�D����D1�F��%LwH'��D!���D1�A�D����1�D����1߉�A�	Ӊ�!�!�	�����1����
1�l$��D��D�A�t$�����A����1��t$���1�D��D���l$�1�D����
A��1�D���D����D1�E��*���4D!�D1�A�D����1�D����1މ�A�	É�!�!�	����D1�A��A��
D1�E��ދ\$�D�AʋL$�A������1ˋL$���1�D��\$�\$���A��D1�E��A��A��
D1�E���D��A��D1�E���9D!�D1�A�D����D1�E��A��D1�A��A�A	���!�A!�A	Ή���D1�A��A��
D1�A��D�D�t$�D�AыT$�A����A1֋T$���A1։�Dt$�Dt$�A����D1�A��A��
D1�A��D�E��A���T$�E��J��ND��D1�A��D!�D1�A�D����D1�E��A��D1�A��A�A	���!�A!�A	։���D1�A��A��
D1�A��D�D�t$�D�A��D$�A����A1ƋD$���A1Ɖ�Dt$�Dt$�A����D1�A��A��
D1�A��D�A���D$�E��Oʜ[D��D1�E��D!�A��D1�A�D����D1�E��A��D1�A��A�A	ˉ�!�A!�D�A	É���D1�A��A��
D1�D�|$�D�D�\$�D�D�t$�A��A��E1�D�\$�A��A��E1�D�\$�Dt$�Dt$�A��E1�D�|$�A��
E1�A��E�A��G���o.hE��D�\$�E1�A��A!�A��E1�E�A��A��E1�A��A��E1�A��E�A	�A��A!�A!�D�E	�A��A��E1�A��A��
E1�E�D�\$�E�D�t$�A��A��E1�D�t$�A��E1�D\$�D�t$�A��E�D�\$�A��E1�D�t$�A��
E1�E��G�| A��A��A��G��9tA��E1�A!�E1�E�A��A��E1�A��A��E1�E��E�A	�E��A!�A!�E	�E��A��E1�E��A��
E1�E�D�\$�E�D�D�l$�E��A��A��A��E1�D�l$�A��E1�D\$�D�l$�A��E�D�\$�A��E1�D�l$�A��
E1�E�A��G�� oc�xA��A��A1�A!�A1�E�A��A��E1�A��A��E1�E��E�E	�E��E!�A!�E	�E��A��E1�E��A��
E1�E�D�D�\$�E�D�l$�E��A��A��A��E1�D�l$�A��E1�D\$�E��A��D�E��A��E1�E��A��
E1�D�A��D��/xȄ��A��1�!�1�A�����D1�A��A��D1�E��A�E	�D��D!�E!�A	�D����D1�E��A��
D1�D�t$�D�D�\$�D�AŋD$�A����D1�D�\$�A��D1�D$�E��A���D��A��
��D1�D1�A��É�1�D��ǌD��D!���1�A�D����1�D����1���A�D	Ɖ�D!�D!�	Ɖ���A��E�D1�A��A��
D1�A��ƋD$�A��D�D�\$���A��D1�D�\$�A��D1�D$�D�\$�AÉ���
��D1�A��1�A�,D��1�D��)����D!�D��1���A�D����1�D����1ȉ�A�	���!�D!�	�����A��E�D1�A��A��
D1���D$�D�D�\$�A����A��D1�D�\$�A��D1�D$�A��A��AƉ���
��A1�D��A1�D1�E�D!�B���lP�D1�D�����D����1�D����1Љ��	��!�!�A��	�A���D1�A��A��
D1�D�d$�D$�ڋ\$�����1؋\$���1؉�E��������Dt$�������
1�D��A��1�D����D�D1�A�D��D!���D1�1�D��D���1؉��	ˉ�!�!�A��	É����D1�A��A��
D1�D�d$�ËD$��l$�����1ŋD$���1�A��,�xq�D����A�D��A��
��1�D��D1�D1�E���!���D1�E�A��A��A��D1�A��A��D1�A��AÉ�A����!�A1���
A1�	�!�	�D�D$�L�T$�D�A�Bt$�\$�T$�L$�|$�DD$�DL$�A�A�ZA�RA�JE�Z A�z$E�B(E�J,H��0[]A\A]A^A_��    AWL���   AVAUATUSH��P  H�L$� ��VH��8H��0H	��VH	��VH��(H	��VH�� H	��VH��H	��VH��H	��VH��H��H	�H�H��L9�u�H�D$8L��$8   L� H�p�Hp�H�H�L��M��I��H��=I��-L1�L1�I��H�H��I��?H��H��L1�H1�H�H�PH��L9�u�H�GL�wE1�L�-L  H�D$�H�G L�\$�H�D$�H�G(H�\$�H�D$�H�G0L�d$�H�D$�H�G8H�T$�H�D$�H�G@H�l$�H�D$�H�GHL�T$�H�D$�I��L��� I��L��H��I��H��H��H��H��N�D�H��2OD
tA�<$�Ⱥ��H��H���m�����t�� D�|$0A��#t�E��t��P���H��H�H�D$0� H��D�8E���o���I���DQ u�H�t$(H�|$0����H�4$H���	���1҅���   L�l$D�d$L�,$L�l$�6f.�     A��u"�T$1�H������H�$�H��H�$fD  A��E����   H�|$(H�t$(����H��I����   A����   ~�A���~   A��u��D$  �D$! 1��fD  H�|$ H���   1�苻��H�I�H�I���T$ �DPu�I�m I���m���1҉�H��$8  dH3%(   u_H��H  []A\A]A^A_ËT$1�H���.���H�T$�H��H�T$�!����T$1�H������H�T$�H��H�T$������   �����f.�     �H�����  =�   ��  =   �<  =�  ��  =   ��  =�� �[  = � t��f����  �J  @���(  @���N  ��1���@���H�t
�    H��@��t	f�  H����t� H������ � ǂ�      ǂ(      H�BH��_  H�BH��_  H�BH��_  H�B H��_  H�B(H��_  H�B0H��_  H�B8H��_  H�B@H��_  H�BH��    ���  ��  @����  @����  ��1���@���H��2  @���  ����  H�H����   ǂ�      ǂ(     H�BH��]  H�BH��]  H�B��]  �B �f.�     ���  �G  @���,  @���B  ��1���@���H���  @����  ����  H� �����   ǂ�      ǂ(     H�BH�[]  H�BH�X]  H�BH�U]  H�B H�R]  H�B(�D  ���  ��  @����  @����  ��1���@���H��Z  @���@  ���'  H�`����   ǂ�      ǂ(      H�BH��\  H�BH��\  H�BH��\  H�B H��\  H�B(�D  ���  �k  @���P  @���f  ��1���@���H���  @����  ����  H������  ǂ�      ǂ(  0   H�BH�[\  H�BH�X\  H�BH�U\  H�B H�R\  H�B(H�O\  H�B0H�L\  H�B8H�I\  H�B@H�F\  H�BH�f�     ���  ��  @����  @����  ��1���@���H��J  @���0  ���  H�@����   ǂ�      ǂ(  @   H�BH��[  H�BH��[  H�BH��[  H�B H��[  H�B(H��[  H�B0H��[  H�B8H��[  H�B@H��[  H�BH�f�     ���  �A  @���&  @���
  ��1���@���H���  @����  ���w  H�p������ ǂ�      ǂ(     H�BH�;[  H�BH�8[  H�BH�5[  H�B H�2[  H�B(H�/[  H�B0H�,[  H�B8H�)[  H�B@H�&[  H�BH�f�     � ������     f�  H�������f��    H�������� �a����     f�  H���B���f��    H���'����� ������     f�  H������f��    H��������    H���'����� �1����     f�  H������f�� ������     f�  H�������f��    H�������� �����     f�  H���b���f��    H���G����f�  ��H��������    � H�z@�����f�     �    ��H������� H�z@��U����    ��H���W���f�  ��H���<���f�  ��H�������� H�z@������    ��H������f�  ��H���1���� H�z@������    ��H������f�  ��H������� H�z@������    ��H�������    ��H���F���f�  ��H���+���� H�z@������    ��H�������f�  ��H�������� H�z@�����f�H�\$�H�l$�L�d$�L�l$�I��L�t$�H��(H��T  �;�°���;L�0踰��H�Pp�;Lc"H��H�Pp袰��H�@�;A�l$J��I)�L��H�����  �{���H�@Hc�H���@
���H����ى�H��H���D���H��L������H�T$dH3%(   L��u)H��[]A\A]� �D���V�����w���I�ŭ  ��蘤���     ��(  �f�     H�\$�H�l$�L�d$�L�l$�L�t$�L�|$�H��8H�_H  I���;�]����;L� �S���H�Pp�;Hc*H��H�Pp�=���H�@I�D�u�;H��D�j(I)�L��H�����5  ����H�@Ic�L�$�    H��H�@H�h�E
���f.�     SH���  袡��H��t?�H��H��A�  ��   @����   @��uaD����A���H�u:A��uA��u[�@ �4@�4[�fD  �f�H��A��t���@ �A����   t����    �A��H���H���fD  �H�xH��A���b��� �A��H��f�H���R����AVAUI��ATUSH�&D  �;�'����;L�0����H�Pp�;Lc"H��H�Pp����H�@�;A�l$J��I)�L��H�����_  �����H�@Hc�L�$�    H���@
   A�   �   H���������  �|$諓��H��H���  1ҁ|$   H�HH�5[  A�   A�   H�����P�����uTH��t1L�%�7  A�<$藓��H���ϓ��H9�tA�<$聓��H��H��薓��H��tH��艕��1�H��H��[]A\� D���   H�KPH�5�  A�   �   H��A����������{���H���   H�5  A�
   A�   �   H���������L����D$=   �9  =  ~���   �  �&���H���   H�5�  A�
   A�   �   H���K����������H���   H�5�  A�
   A�   �   H�������������H���   H�5c  A�
   A�   �   H��������������H���   H�5:  A�
   A�   �   H���������j���L�%6  A�<$����H���>���H9������A�<$����H��H�������u���@ 1��%����H�5�  ����H��H��������J��� ���   �  ����������ff.�     H�\$�H�l$�L�d$�L�l$�I��L�t$�H��(H�a5  �;�b����;L�0�X���H�Pp�;Lc"H��H�Pp�B���H�@�;A�l$J��I)�L��H������   ����H�@Hc�;L�$�    H���@
�    H����t	f�  H����t� H��H��[]A\A]�H�kD��L��H����������H���E  �@��t�f�  H����@��t��    ��H���x���H�{�R���H��1�������H�{�=���H�{�4���H��1��ڏ���q���D  H�R闍���    H�\$�H�l$�H��L�d$�H��H�����H�{L�c��(  �����L��H����Hc�H���J���H�{�����H�{H�l$H�$L�d$H��閎��fD  H�鷏���    H��G����    H�駍���    H��SH��tMH��^�����H�߾�   ��   @����   @��ue��1���@���H�u=@��u��uH���ʎ��1�[�fD  � �� f�  H����t����     �    H��@��t���fD  �    ��H���f�     � H�{@���d����f�  ��H���\���ffffff.�     AWAVAUATI��USH��(H�-P0  �} �P����} L�(�E���H�Pp�} HcH��H�Pp�.���H�@�} D�{H��I)�I�$I��A�]�D�p(F�$;����H�@Mc�} J���@
  E1�H���)����;袇��H��+  L��  H�
  E1�H��������;�t���H�-�+  L�@  H�
  H�5R  E1�H��H���.���H� �;�@(   蝆��L�p  H�
  H�56  E1�H��H�������H� �;�@(
   �i���L�<  H�
  H�5  E1�H��H���Ƈ��H� �;�@(   �5���L�  H�
  H�5�
  E1�H��H��蒇��H� �;�@(   ����L��
  H�5�
  E1�H��H���^���H� �;�@(   �ͅ��L��
  E1�H��H���*���H� �;�@(   虅��L�l
  E1�H��H�������H� �;�@(   �e���L�8
  H��E1�H�����H� �;�@(   �1���L�
  E1�H��H��莆��H� �;�@(   �����L��  H�
	  H�5O
  E1�H��H���Z���H� �;�@(   �Ʉ��L��  H�
  E1�H��H���&���H� �;�@(   蕄��L�h  H�
  E1�H��H������H� �;�@(	   �a���L�4  H�
  E1�H��H��辅��H� �;�@(   �-���L�   H�
  H�
  H�
  H�
  H�
  H�
  E1�H��H��诃��H� �;�@(   ����L��	  H�
  H�5�  E1�H��H���{���H� �;�@(
   ����L��	  H�
  E1�H��H���G���H� �;�@(   趁��L��	  H�
  E1�H��H������H� �;�@(   肁��L�U	  H�
H %s%02x 
block 
blockcnt:%u
 :%02x file, s Digest::SHA::shadump Digest::SHA::shaclose blockcnt lenhh lenhl lenlh lenll file v5.14.0 5.61 SHA.c Digest::SHA::shaload Digest::SHA::shaopen $$$ Digest::SHA::sha512_hex Digest::SHA::sha512_base64 Digest::SHA::sha224 Digest::SHA::sha256_hex Digest::SHA::sha384_hex Digest::SHA::sha512 Digest::SHA::sha512224 Digest::SHA::sha1_hex Digest::SHA::sha256 Digest::SHA::sha384_base64 Digest::SHA::sha1_base64 Digest::SHA::sha224_hex Digest::SHA::sha512224_hex Digest::SHA::sha512256_base64 Digest::SHA::sha384 Digest::SHA::sha256_base64 Digest::SHA::sha224_base64 Digest::SHA::sha1 Digest::SHA::sha512256 Digest::SHA::sha512224_base64 Digest::SHA::sha512256_hex Digest::SHA::hmac_sha1_base64 Digest::SHA::hmac_sha1 Digest::SHA::hmac_sha1_hex Digest::SHA::hmac_sha224 Digest::SHA::hmac_sha384_hex Digest::SHA::hmac_sha256_hex Digest::SHA::hmac_sha512224 Digest::SHA::hmac_sha512 Digest::SHA::hmac_sha512256 Digest::SHA::hmac_sha256 Digest::SHA::hmac_sha224_hex Digest::SHA::hmac_sha384 Digest::SHA::hmac_sha512_hex Digest::SHA::algorithm Digest::SHA::hashsize $;@ Digest::SHA::add Digest::SHA::digest Digest::SHA::Hexdigest Digest::SHA::B64digest lenhh:%lu
lenhl:%lu
lenlh:%lu
lenll:%lu
        Digest::SHA::hmac_sha512224_base64      Digest::SHA::hmac_sha512_base64 Digest::SHA::hmac_sha512224_hex Digest::SHA::hmac_sha512256_hex Digest::SHA::hmac_sha256_base64 Digest::SHA::hmac_sha384_base64 Digest::SHA::hmac_sha224_base64 Digest::SHA::hmac_sha512256_base64                      "�(ט/�B�e�#�D7q/;M������ۉ��۵�8�H�[�V9����Y�O���?��m��^�B���ؾopE[����N��1$����}Uo�{�t]�r��;��ހ5�%�ܛ�&i�t���J��i���%O8�G��Ռ�Ɲ�e��w̡$u+Yo,�-��n��tJ��A�ܩ�\�S�ڈ�v��f�RQ>�2�-m�1�?!���'����Y��=���%�
�G���o��Qc�pn
g))�/�F�
�'&�&\8!.�*�Z�m,M߳��
e��w<�
jv��G.�;5��,r�d�L�迢0B�Kf�����p�K�0�T�Ql�R�����eU$��* qW�5��ѻ2p�j��Ҹ��S�AQl7���LwH'�H�ᵼ�4cZ�ų9ˊA�J��Ns�cwOʜ[�����o.h���]t`/Coc�xr��xȄ�9dǌ(c#����齂��lP�yƲ����+Sr��xqƜa&��>'���!Ǹ������}��x�n�O}��or�g���Ȣ�}c
�
��<L
B  L   �  ���f   B�E�E �B(�A0�A8�G�
8A0A(B BBBA   $   �  8����    Q0��g
H�      ,     ����    A�D�G a
AAA     L   L  0���f   B�B�E �B(�A0�D8�G��
8A0A(B BBBA      �  P����          $   �  8����   T����L0�
A    �  ����|    N ��L
F $   �  ���w   T����L0�"
F    $  h���e           L   <  �����   B�B�B �B(�D0�A8�DP]
8A0A(B BBBH    L   �  0����   B�B�B �E(�A0�A8�DP�
8A0A(B BBBH    <   �  �����   B�L�H �G(�F0��
(A BBBB       ����    A�P       $   <  ����x    A�D�D eHA<   d  �����    B�E�A �A(�D@�
(A ABBD        �  ����           $   �  �����   b@������2
D   �  8���           $   �  0����   b@������
H$   $  �����    A�R
EI
G     <   L  P����   B�B�E �A(�A0�Y
(A BBBE  L   �  �����   B�B�B �B(�A0�D8�JP�
8A0A(B BBBA    L   �  �����   B�B�B �E(�A0�A8�DP�
8A0A(B BBBH    $   ,  �����    PK
EQ
Gj   L   T  �����   B�B�B �B(�D0�A8�D`�
8A0A(B BBBG    <   �  ����   B�B�E �A(�A0�e
(A BBBI  4   �  �����   B�A�A �D0�
 DABD     $     0���}   T����L0�%
K <   D  ����   B�J�D �H(�D0d
(D ABBA       �  X���	              �  P���j    J��L �O    �  ����	              �  ����	              �  ����	                �����    D�U
G   L   $  H���
8A0A(B BBBG    <   t  ���9   B�B�B �A(�A0�)(A BBB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            �                     d             �      
       �                           �             p                                                      �      	              ���o    �      ���o           ���o    *      ���o                                                                                                                                                                                                                                           ��                      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F                      ��                              #Eg�����ܺ�vT2����            ؞��|6�p09Y�1��Xh���d�O��g�	j��g�r�n<:�O�RQ�h��ك��[؞�]����|6*)�b�p0ZY�9Y���/1��g&3gXh�J�����d
                               #         �� ��@[#   &   +   BE��>���|f.<�.6bx���J�qX������                             
 `              �                     i                     �                      �                                                                  �                     �                      �                     ?                     �                                             9                     M                     �                     Z                     �                     �                     �                      �                     a                     �                     a                       �                      0                     �                      p                     v                     8                                            R   "                                        u                      �   ���@              '    �"      �       �   ���@              �                   �    �#                0!      D      �   ���@                  
 `                  
           �?         &           �?         
   �@����%"$  h   �0����%$  h   � ����%$  h
$  h   � ����%$  h   ������%�#  h   ������%�#  h   ������%�#  h   ������%�#  h   �����%�#  h   �����%�#  h   �����%�#  h   �����%�#  h   �p����%�#  h   �`����%�#  h   �P����%�#  h   �@����%�#  h   �0���H��H�u"  H��t��H��Ð��������H��#  H�=z#  UH)�H��H��w]�H�"  H��t�]��@ H�Q#  H�=J#  UH)�H��H��H��H��?H�H��H��u]�H�"  H��t�]��@ �=#   u'H�=�!   UH��tH�=�"  �����h���]��"  ��fffff.�     H�=�   tH��!  H��tUH�=�  H����]�W����R�����UH�5H
  �   H��SH��(�����H�  E1��$    A�0   �   H��H���/���H��H��tgH� �@
H��H�WpH�WH��H)�H����tH��  �I���f�     H��NH�vH�P��    ��   �1���L��P  H��H���?���1�E1�E1�H��H���D$    H�D$    �$   H���a���H��A�L$$I�T$0H��t'H�=p  1�����H��H���&���H��H���;��� H�=�  1��j���H����D  AWH�  AVAUI��ATUSH��HH�GpH�oL�'Lc0H��H�GpA�^Hc�H�D$0H�L$0H��H�D$8H�t� �   ����J�D� L��H�
H�H�x tUH�U L��L��H���9���H�H�r(H��t�V���z  ���҉V��  H�f�b\�H�H�B0    H� H�@(    I�GH�t$(1�H��Lc@H�HF�L 	� L�t$�$   �D$����H���V  H��H�U H����   �ME1��$    A�   L��H���{���H��I���.  H�p�F�Ѓ�����H�V�B �  ����H�(  1�H���J����O���D  H�P�B �  �����H�ƺ   H��H�D$ �:���H�D$ �����L��H���5���H�
        %-p is not a valid Fcntl macro at %s line %d
   Couldn't add key '%s' to %%Fcntl::      Couldn't add key '%s' to missing_hash   Fcntl FCREAT v5.14.0 1.11 Fcntl.c Fcntl::AUTOLOAD Fcntl::S_IMODE Fcntl::S_IFMT Fcntl:: Fcntl::S_ISREG Fcntl::S_ISDIR Fcntl::S_ISLNK Fcntl::S_ISSOCK Fcntl::S_ISBLK Fcntl::S_ISCHR Fcntl::S_ISFIFO DN_ACCESS DN_MODIFY DN_CREATE DN_DELETE DN_RENAME DN_ATTRIB DN_MULTISHOT FAPPEND FASYNC FD_CLOEXEC FNDELAY FNONBLOCK F_DUPFD F_EXLCK F_GETFD F_GETFL F_GETLEASE F_GETLK F_GETLK64 F_GETOWN F_GETSIG F_NOTIFY F_RDLCK F_SETFD F_SETFL F_SETLEASE F_SETLK F_SETLK64 F_SETLKW F_SETLKW64 F_SETOWN F_SETSIG F_SHLCK F_UNLCK F_WRLCK LOCK_MAND LOCK_READ LOCK_WRITE LOCK_RW O_ACCMODE O_APPEND O_ASYNC O_BINARY O_CREAT O_DIRECT O_DIRECTORY O_DSYNC O_EXCL O_LARGEFILE O_NDELAY O_NOATIME O_NOCTTY O_NOFOLLOW O_NONBLOCK O_RDONLY O_RDWR O_RSYNC O_SYNC O_TEXT O_TRUNC O_WRONLY S_IEXEC S_IFBLK S_IFCHR S_IFDIR S_IFIFO S_IFLNK S_IFREG S_IFSOCK S_IREAD S_IRGRP S_IROTH S_IRUSR S_IRWXG S_IRWXO S_IRWXU S_ISGID S_ISUID S_ISVTX S_IWGRP S_IWOTH S_IWRITE S_IWUSR S_IXGRP S_IXOTH S_IXUSR LOCK_SH LOCK_EX LOCK_NB LOCK_UN SEEK_SET SEEK_CUR SEEK_END _S_IFMT FDEFER FDSYNC FEXCL FLARGEFILE FRSYNC FTRUNC F_ALLOCSP F_ALLOCSP64 F_COMPAT F_DUP2FD F_FREESP F_FREESP64 F_FSYNC F_FSYNC64 F_NODNY F_POSIX F_RDACC F_RDDNY F_RWACC F_RWDNY F_SHARE F_UNSHARE F_WRACC F_WRDNY O_ALIAS O_DEFER O_EXLOCK O_IGNORE_CTTY O_NOINHERIT O_NOLINK O_NOTRANS O_RANDOM O_RAW O_RSRC O_SEQUENTIAL O_SHLOCK O_TEMPORARY S_ENFMT S_IFWHT S_ISTXT   ;D      ����`   `����    ����   @����   P���  ����8  ����X             zR x�  $      (����   FJw� ?;*3$"    4   D   �����    A�P�D@E
AADh
AAF $   |   X���   J��V0����
B  $   �   P���   J��V0����
E  $   �   8���D   J��V0����
D     �   `����    J��L@�     L     @���   B�I�B �E(�A0�A8�D�q
8A0A(B BBBE                                                                                                                                                                                                                                                                                                                                                                                 �                                      B*      	              L*      	              V*      	              `*      	              j*      	              t*      	               ~*                �    �*                    �*                     �*      
              �*                    �*      	              �*                     �*                    �*                    �*                    �*      
             �*                    �*      	              �*             	       �*                    +                   +                     +                    +                    '+      
              2+                    :+      	              D+                    M+      
              X+                    a+             
       j+                    r+                    z+                    �+      	               �+      	       @       �+      
       �       �+             �       �+      	              �+                    �+                     �+                     �+             @       �+              @      �+                    �+                    �+             �       �+                     ,                    ,      	              ,                    !,      
              ,,      
              7,                     @,                    G,                   O,                   V,                     ],                    e,                    n,             @       v,              `      ~,                     �,              @      �,                    �,              �      �,              �      �,              �      �,                    �,                     �,                    �,                    �,             8       �,                    �,             �      �,                    �,                    �,                    �,                    -                    -             �       -             �        -                    (-                    0-             @       8-                    @-                    H-                    P-                    X-                     a-                    j-                    s-              �                                                      �)             {-             �-             �-             �-      
       �-             �-             �-             �-      	       �-             �-             �-             �-             �-      
       �-             �-      	       �-             �-             .             .             .             .             &.             ..      	       8.             @.             H.             P.             X.             a.      
       �                           �?             �                           �             �
             �
      ���o           ���o    f
      ���o    �                                                                                                                                                               �=                      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      �@      Fcntl.so    �9 .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .data.rel.ro .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                 �      �      $                              "             �      �      L                              ���o       @      @      H                             (             �      �                                 0             �      �      �                             8   ���o       f
      f
      X                            E   ���o       �
      �
                                   T             �
      �
      �
   8         $      %                                                                                                    B                          <                          C                      "   *       >           A   :                      1               	       =   D       
 H              l                     �                     �                     �                      �                                            ]                                           �                     2                     <                     z                     h                     !                     s                     <                     �                     1                     �                     }                     	                     D                     �                                           c                                            �                     	                     �                      �                     �                     �                      �                                          �                     �                                          5                     �                      �                      E                     �                      �                      [                       i                                          M                                          o                     2                       \                     �                     L   "                   �                     o                      P                     �   ���Q              �   ���Q              �    �2      �       �   ���Q              �    �1      �       �     1      ^       +   
 H              S     3      h          
9      �L             9      �L             9      �L             )9      �L             39       M             ?9      M             L9      0M             Y9      HM             e9      `M             r9      xM             }9      �M             �9      �Q             �Q      �O         A           �O                    �O                    �O         <           �O                    �O                    �O                    �O         >           �O         -           �O         3           �O         6            P                    P                    P                    P                     P                    (P                    0P         	           8P         
           @P                    HP                    PP         
   �@����%28  h   �0����%*8  h   � ����%"8  h
8  h   ������%8  h   ������%�7  h   ������%�7  h   �����%�7  h   �����%�7  h   �����%�7  h   �����%�7  h   �p����%�7  h   �`����%�7  h   �P����%�7  h   �@����%�7  h   �0����%�7  h   � ����%�7  h   �����%�7  h   � ����%�7  h   ������%�7  h    ������%�7  h!   ������%z7  h"   ������%r7  h#   �����%j7  h$   �����%b7  h%   �����%Z7  h&   �����%R7  h'   �p����%J7  h(   �`����%B7  h)   �P����%:7  h*   �@����%27  h+   �0����%*7  h,   � ����%"7  h-   �����%7  h.   � ����%7  h/   ������%
7  h0   ������%7  h1   ������%�6  h2   �����H��H�
A�P1�A��   �L�-  A�1�E�
A��   �@ H��  dH�%(   H��$  1��@ H��H=   tTD�GE��D�u��@u1H��   H�������H��$  dH3%(   u%H��  �fD  H�����f�     ������������@ H��  dH�%(   H��$  1��@ H��H=   tTD�GE��D�u��@u1H��   H���a���H��$  dH3%(   u%H��  �fD  H�����f�     ��������d���@ AWAVA�   AUATUH��SH��H��h  H��$�  H��$�  H�|$0H�t$8L�L$H�D$@H��$�  H�T$(dH�%(   H��$X  1�H9�H�D$Hv5H��$X  dH3%(   D���g  H��h  []A\A]A^A_�f�     f�E   M���"����     I��H�D$0H�L$0�1�f��u�  H=�  ��  �TAH���҈TPu�H�T$(H�|$P�B@�e  �*���I��M���z  H�T$(L�=B����B�������@�T$$�#   L��A��H��tu�x.��   H9���   �PL�uL�@f��f�U tD  L9�v{A� I��fA�I��f��u�L9�va�L$$H�T$L��H���-�����uqf�E   L��A��H��u�H�T$(E1�L���B@uA���������D  fA�<$.�T���H9��i���I��fA�  A�   H�T$(L���B@t��R �Y���fD  H�D$HL�L$@I�V�L�D$H�t$8H��H�|$0H�D$H�D$(H�$�   �������A���H�D$(L�x(������R0I������H�5�  H�|$P�   �����a���H�D$(H�HH��tJ1�H�t$0�D  H��H=   t%�F�҈TPu�A�7H�|$P�х�uH�T$(�BtA���������E1������o���ffffff.�     AUI��ATI��UH�͹   SH��   A� f����   1�f��/M��M��u"�L�     I��fA�B�A�f��/t-f��t(f��H�I��L9�sٸ   H�ĸ   []A\A]�fD  ��uCA�M��M��f��/u�I��L9�r�I��fA�/ A� f��/�j���I�D$M��H9�r�I����H��$�   L�$H��M��L��L��H�D$H��$�   H�D$�
����q���H��$�   H��$�   H�t$ fA�$  L��H��H��8H��������1����6���H��$�   �@t fA�|$�/t�D$8% �  = @  t[= �  t$H��$�   H��$�   L��@H������������H��$�   H�t$ H��L��H��@�������u��D$8% �  = @  u�I�D$H9������fA�$/ fA�D$  �f�     AVAUI��ATUSH��H�� @  ��nH�D$    f��~��  L�t$ D�L��L��Mc��%�    f��[tjf��*t<f��� H��f�H���f��H�p��   f��?u�f�?��K   H��H����f��K   L9�tf�y�*�H��t�f�*�H��H��� �PD��A��!�~   f��t'H�FH��f.�     �:f��]��  H��f��u�H�F�f�[ H��A��!HE��S���f�  f�|$  usE9��C�  � t+�k1�H�� @  []A\A]A^�fD  H�p�P�u��� ��0H�
H��H��H9�r�f�  �kM���T$ �����    A��!f�[�H�Qu
H�Qf�A!��6�f.�     H����]tGH�ʁ��   H�Jf�2�0f��-u��pf��]t<f��� f�B-�H�Jf�r�pH��H����]u�f�]��K   H���.��� H���-   �D  �u��   ��   �����H�T$�kH��L�����������     H�=�  �4���H������������������H��������kA�U �|����E H��I���  f�H��f�������f.�     H9�������E H��f�H��f��u�f�  �kM���T$ �!���D�����fD  ATI��UH��SH���f��{t]H���@ �f��{t'H��f��u�L��H������H��[]A\�f.�     H�L$L��H��H���-   ��u��D$H��[]A\�f�}u�f� u��fff.�     AWAVI��AUATUSH��   H9�H�T$�U  L�l$H��L�� �H��f�
H��H9�u�H��H��H)�H��M�|E�WfA�  H�wf����   A��H��E1��.f�     fA��{��   fA��}��   D�KH��fE��t[fA��[u�D�KH�KfE����   fA��]tzH���D  fA��]tH��D� fE��u�fE��H��t�D�HH�XfE��u� H�t$L���C���A��    D�KA��H���u���fD  E��tA���X���f�E��H���H9�H��H��v�G f��,tYH�uH9�w5�UH��f��[��   v�f��{��   f��}u�E��t-H�uA��H9�v�A�    H��   1�[]A\A]A^A_�E��u�H9���   H��L��D  �0H��f�2H��H9�w�H��H�/H��I�tG1�@ �Tf�H��f��u�H�t$L���Y���H�}A�H���<���A���/�����EH�uH��f��u�fD  H���f��tf��]u�f�������H�rH�������L���{���L�l$M�������fff.�     ��H��   �    �����   H�A    �A    �AH�Q�A    uY�L�GH��L��$�  ��t f�H��L9�sA�I����u��   f�   H��H����   �<���H��   �@ D�H�WE��E��t|I��H��L��$�  �(�    fD�I��H��L9�s�D�H��E��E��t�A��\u�E�PA�\@  E��t
H��H�WpH�WD�aH��H)�H������   Hc
H��H�WpH�WH��H)�H����tH��  ���� H��NH�vH�P��    ��   �����H��P  H�=�  H��1��J$H�R0�����H��H���_���H��H������@ AWAVAUI��ATUH��SH��hH�GpL�7HcH��L��H�GpH�GD�zH��H)�H�����  Mc�Hc�J�4�H��I)��F
  H�58  L������H�
      Couldn't add key '%s' to %%File::Glob:: ;�      h����   �����   8���X  H���p  ����  ����   ����H  H���h  �����  �����  ����  ����x  h����  ����  (���8  ����h  �����  �����  (����  ����             zR x�  $      ����@   FJw� ?;*3$"    d   D   �����   B�B�B �B(�A0�A8�D�6
8A0A(B BBBB$
8F0A(B BBBE    �   ����           �   �   ����k   B�B�E �B(�A0�A8�GP�
8C0A(B BBBAl
8F0A(B BBBEL
8F0A(B BBBEn
8F0A(B BBBC        \  ����           $   t  �����    D��
LA
G        �  h����    G� b
G       �  �����    G� b
G    L   �  H����   B�B�H �B(�A0�D8�J�!o
8A0A(B BBBJ    <   ,  �����   B�E�D �I(�G�X
(A ABBG    \   l  ����   B�B�E �A(�A0�JЀ$
0A(A BBBG�
0A(A BBBC    D   �  X����    B�D�D �D0s
 AABK_
 AABA       L     �����   B�B�E �B(�A0�A8�G�@�
8C0A(B BBBA   $   d  ����%   I�@�
E�
A     ,   �  ����^    B�D�A �SAB         �  ���           $   �   ����    J��V0����
I     �  �����    A�  L     `���h   B�B�B �E(�A0�D8�D�b
8A0A(B BBBH   L   d  �����   B�B�B �B(�D0�A8�Dp"
8A0A(B BBBC                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            p      0                      �8      
       ���������8                     �8             @       
9      
       �       9                    9      
        @      )9      	              39                    ?9                    L9                    Y9                     e9             ��������r9      
              }9      
              �9             �.                                     �             H      
             h      
                                  �O             �                           �             �             �      	              ���o    �      ���o           ���o    �      ���o                                                                                                                                                                                   �M                      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �Q      ����Glob.so �d� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .data.rel.ro .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                 �      �      $                              "             �      �      (                              ���o                   P                             (             h      h      x                          0             �
      �
                                   8   ���o       �      �      �                            E   ���o       �      �      @                            T             �      �      �                           ^             �      �      �                          h             H      H                                    c             `      `      @                            n             �      �      t                             t             8      8      	                              z              8       8      �                             �             �9      �9      �                              �             �:      �:      �                             �              L       L                                    �             (L      (L                                    �             0L      0L                                    �             @L      @L      �                              �             �M      �M      �                           �             �O      �O      X                             �             �O      �O      �                            �             �Q      �Q                                    �             �Q      �Q                                    �                      �Q                                                          �Q      �                              FILE   cdfb9aa8/auto/IO/IO.so  IELF          >    `      @       PB          @ 8  @                                 �5      �5                    h=      h=      h=      �      �                    �=      �=      �=      �      �                   �      �      �      $       $              P�td   82      82      82      �       �              Q�td                                                  R�td   h=      h=      h=      �      �                      GNU �(V��Ŕ��s8��}
ǤR    %   D   A   &   %       ?   -      '                 #       )   0   ,         3   /               4   1       +      C   .   *             5                                                            
      =       9   6                B   @       >   7   2       (      !      "                     :   <       8   $                                 ;                  0         � H��
 �              �                     j                                          �                      �                      	                                            �                     *                     �                     �                     _                     �                     V                     �                                          X                     �                                            �                      �                     �                     z                     /                                          �                     �                     1                     �                     �                     �                     =                     �                     Z                     �                                           a                       �                     �                      �                     w                     8                       0                     �                      R   "                   �                      u     `      �           
 �              �    p            "   ��XA              .   ��`A              ?    �)      �           �      {          ��XA              �     `      ,      M    �#      E          `(            �    P            �    �       a      d    p*      U       �    �*      �      �    @&            D                     "      �       __gmon_start__ _init _fini _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize _Jv_RegisterClasses XS_IO__Socket_sockatmark Perl_sv_2io Perl_PerlIO_fileno Perl_sv_newmortal Perl_sv_setiv Perl_sv_setpvn Perl_croak_xs_usage XS_IO__Handle_sync fsync __errno_location XS_IO__Handle_setbuf Perl_croak_nocontext XS_IO__Handle_flush Perl_PerlIO_flush XS_IO__Handle_untaint Perl_mg_set XS_IO__Handle_clearerr Perl_PerlIO_clearerr XS_IO__Handle_error Perl_PerlIO_error XS_IO__Handle_ungetc PerlIO_ungetc Perl_sv_2iv_flags XS_IO__Handle_blocking fcntl Perl_newSViv Perl_sv_2mortal XS_IO__Poll__poll Perl_newSV Perl_sv_free Perl_sv_free2 XS_IO__File_new_tmpfile PerlIO_tmpfile Perl_newGVgen Perl_hv_common_key_len Perl_do_openn Perl_newRV Perl_gv_stashpv Perl_sv_bless Perl_sv_2pv_flags XS_IO__Seekable_setpos PerlIO_setpos XS_IO__Seekable_getpos PerlIO_getpos XS_IO__Handle_setvbuf Perl_croak boot_IO Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck Perl_newXS Perl_newXS_flags Perl_gv_stashpvn Perl_newCONSTSUB Perl_call_list libc.so.6 _edata __bss_start _end GLIBC_2.2.5                                                                                                                           ui	   3      h=             0      p=             �      PA             PA      P?                    X?         :           `?         B           h?         ;           p?         C           x?         4           �?         <           �?                    �?         A           �?         0           �?         =           �?         ?           �?         8           �?         7           �?         >           �?         &           �?         2           �?         +           �?         .            @                    @                    @                    @                     @                    (@                    0@         	           8@         
           @@                    H@                    P@         
*  h   �����%*  h   �p����%�)  h   �`����%�)  h	   �P����%�)  h
   �@����%�)  h   �0����%�)  h   � ����%�)  h
)  h&   �����%)  h'   �p����%�(  h(   �`����%�(  h)   �P���H��H�'  H��t��H��Ð��������H��(  H�=�(  UH)�H��H��w]�H��&  H��t�]��@ H��(  H�=�(  UH)�H��H��H��H��?H�H��H��u]�H��&  H��t�]��@ �=a(   u'H�=�&   UH��tH�=B(  �-����h���]�8(  ��fffff.�     H�=@$   tH��&  H��tUH�=*$  H����]�W����R�����H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�O�jH��H)�H������   Hc�H�4�L�,�    �����H�pH���#������,���L�sA��H���m���M�A���I�tE��t<H�CIc�H��H�4��)���LkH�l$L�d$L�t$ L�+H�$L�l$H��(�D  H�CH�Z  �
   H��H�4������H�;  �v���fD  H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�O�jH��H)�H������   Hc�H�4�L�$�    �����H� H�p(H����   H�������������L�sA��H���a���M�A���I�tE��t@H�CIc�H��H�4�����LcH�l$L�l$L�t$ L�#H�$L�d$H��(�f�     H�CH�J  �
   H��H�4������f������    H�kH�������L�H�E �H�  �D���@ USH��H��H�OpH�HcH��H�OpH�O�jH��H)�H����~)Hc�H�4������H� H�x( uH�CH�D��H�H��[]�H��  �����H�5�  H�=�  1�����D  H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�O�jH��H)�H������   Hc�H�4�L�$�    �O���H� H�p(H���   H���'���L�sA��H������M�A���I�tE��t7H�CIc�H��H�4��t���LcH�l$L�l$L�t$ L�#H�$L�d$H��(�H�CH��  �
   H��H�4�������f������    H�kH���9���L�H�E �H�y  ����@ H�\$�L�d$�H��H�l$�L�l$�H��8H�OpH�HcH��H�OpH�OD�bH��H)�H������   H�GMc�N�,�    J�4��@# tvH�PH�GH��H�,�����H��t|H� 1Ҁ��   H�CH��H��N�d���e����E@tH��H������I�l$LkH�l$ L�d$(L�+H�\$L�l$0H��8��    H�t$�>���H�t$H��H������H��u������H�������    �y���H�[  ����fD  H�\$�L�d$�H��H�l$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�OD�bH��H)�H������   Mc�J�4�N�,�    ����L�pH�C�@# ��   H�PH�CH�,�M��t[L��H�������1�H�CH��H��N�d���:����E@tH��H���Y���I�l$LkH�l$L�d$L�t$ L�+H�$L�l$H��(������H�������    �@ H��� ���H���x���H�A  �l���fff.�     H�\$�L�d$�H��H�l$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�OD�bH��H)�H������   Mc�J�4�N�,�    �����L�pH�C�@# ��   H�PH�CH�,�M��tcL��H���p���Hc�H�CH��H��N�d�������E@tH��H���8���I�l$LkH�l$L�d$L�t$ L�+H�$L�l$H��(��    ����H�������    �@ H�������H���p���H�  �D���@ H�\$�H�l$�H��L�d$�L�l$�L�t$�L�|$�H��8H�OpH�HcH��H�OpH�O�jH��H)�H�����  Hc�H�4�L�,�    �����L�pH�CH�t��F
  ������T$,H�t$ L���_�������xQ�D$(H�T$L�t$L�<�I�� I�EIc$L��J�40����I�EI�T$L��I��J�t0I������M9�uȋE��tQ�����EtWH�l$ImHc�L���S���L��H������H�E H�D$IEI�E H��8[]A\A]A^A_��     H��L�������� H��L�������뜋T$,H�t$ L���������s���ff.�     H�\$�L�d$�H��H�l$�L�l$�L�t$�H��HH�OpH�HcH��H�OpH�OD�bH��H)�H������  ���r  Ic�H�4�L�$�    �F
   H��H�4������f������    H�kH�������L�H�E �H��  �T���@ H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�O�jH��H)�H������   Hc�H�4�L�$�    �����L�hM��t^L�sH���Z���L��M�I�H�CH�4��t�����tH�CH��@  H��LcH�l$L�l$L�t$ L�#H�$L�d$H��(�D  ������    H�CH��@  H���H�5  �`���H��H�WpH�Hc
H��H�WpH�WH��H)�H����tH�5_  1��X����     H�5d  H�=  1��K���ff.�     AW�   AVAUATUSH��H��H�WpL�wH�Lc:H��H�WpH�,  H�D$A�oLc�K�4�N�,�    � ���H�t$K��H�
   H�������1�H��H������H�  H��H��H�������   H���w���H��  H��H��H�������   H���U���H��  H��H��H���p���1�H���6���H��  H��H��H���Q����   H������H��  H��H��H���/����   H�������H��  H��H��H���
F  $   l   (���,   J��V0����
J  ,   �   0���{    A�A�G N
AAA     $   �   ����   J��V0����
A  $   �   x���   J��Q@���
H    $     p���   J��V0����
A  $   <  h���   J��V0����
H  $   d  `���a   J��[@�����
K,   �  �����   J��[@����<
G       L   �  h���E   B�B�B �E(�A0�A8�Dp�
8A0A(B BBBI    $     h���   J��VP���*
F $   4  `���   J��V0����
B  $   \  X����    J��V0����
F     �   ���U    D    L   �  h����   B�G�B �B(�A0�A8�GP�8A0A(B BBB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               0      �                                  �      
             X      
       ?                           �?             �                           �             �                   	              ���o    �      ���o           ���o    �      ���o                                                                                                                                                                                                                                                   �=                      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      PA      IO.so   _D� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                  �      �      $                              "             �      �      �                              ���o       �      �      �                             (             X      X      `                          0             �
      �
      ?                             8   ���o       �      �      �                            E   ���o       �      �                                   T             �      �                                 ^             �      �      �                          h             �      �                                    c             �      �      �                            n             `      `                                    t             �/      �/      	                              z      2       �/      �/      �                            �             82      82      �                              �             �2      �2      �                             �             h=      h=                                    �             p=      p=                                    �             x=      x=                                    �             �=      �=      �                           �             P?      P?      �                             �             �?      �?      h                            �             PA      PA                                    �             XA      XA                                    �                      XA                                                          dA      �                              FILE   4f415a77/auto/List/Util/Util.so  ihELF          >    �      @       �b          @ 8  @                                 TO      TO                    P]      P]      P]      `      h                    h]      h]      h]      �      �                   �      �      �      $       $              P�td    J       J       J      �       �              Q�td                                                  R�td   P]      P]      P]      �      �                      GNU ^�nPX��&�4���uD��`    C   R       )   6   0   K   4   2      $       3      +      (   8   O                                    >       N   A   Q       C       "   -   7      .       '   M           P      F          1                  #   B         %   :   L   I           5   !   9                                                                 
   <          
 `              �                     �                     �                     �                     &                     �                      �                     �                                            �                     ,                     �                     z                                          <                     �                                          �                                          A                                            M                     �                      �                     z                     �                     �                     �                      9                     ,                     �                     #                     Q                     �                     /                     N                     
                                          �                     [                                            �                      �                     �                                           x                     �                     �                     Z                     2                       �                     H                                          L   "                   ;                     �                     j                         
 `              �    C      f      m   ���a              y   ���a              b    p(      �      �     $      ]       �             e      �    #      	      J    '      Q          p,      A      ,    �8      �      �     @      �       f   ���a              o     �      p       w    `"      �       �    �$      1      :    �1      �      e    �>            �    �?      v      �    P+             __gmon_start__ _fini _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize _Jv_RegisterClasses XS_Scalar__Util_isweak Perl_croak_xs_usage XS_Scalar__Util_set_prototype Perl_sv_setpvn Perl_croak_nocontext XS_Scalar__Util_looks_like_number Perl_looks_like_number Perl_sv_setiv Perl_mg_set Perl_mg_get Perl_sv_newmortal Perl_amagic_call XS_Scalar__Util_readonly XS_Scalar__Util_isvstring Perl_mg_find XS_Scalar__Util_tainted Perl_sv_tainted XS_Scalar__Util_weaken Perl_sv_rvweaken XS_Scalar__Util_refaddr Perl_sv_setuv XS_Scalar__Util_reftype Perl_sv_reftype Perl_sv_setpv XS_Scalar__Util_blessed XS_Scalar__Util_dualvar Perl_sv_upgrade Perl_sv_2pv_flags Perl_sv_magic Perl_sv_2nv_flags Perl_sv_2iv_flags Perl_sv_2uv_flags XS_List__Util_shuffle drand48_r Perl_seed srand48_r XS_List__Util_min Perl_sv_2bool_flags XS_List__Util_first Perl_sv_2cv Perl_push_scope Perl_save_int Perl_save_vptr Perl_pad_push Perl_save_pushptr Perl_save_sptr Perl_pop_scope Perl_sv_free2 Perl_cxinc Perl_new_stackinfo Perl_sv_free Perl_PerlIO_stderr PerlIO_printf Perl_my_exit XS_List__Util_reduce Perl_gv_fetchpv Perl_sv_setsv_flags XS_List__Util_minstr Perl_sv_cmp_flags XS_List__Util_sum Perl_sv_setnv boot_List__Util Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck Perl_newXS_flags Perl_gv_stashpvn Perl_hv_common_key_len Perl_gv_init Perl_call_list Perl_gv_add_by_type libc.so.6 _edata __bss_start _end GLIBC_2.2.5                                                                                                                                               \         ui	   ~      P]             �      X]             `      �a             �a      8_         
           @_         <           H_         =           P_         C           X_         D           `_         Q           h_         K           p_         E           x_         L           �_                    �_         N           �_         M           �_         F           �_         G           �_         H           �_         )           �_         B           �_         I           �_         3           �_         O           �_         7           �_         P            `                    `                    `                    `                     `                    (`                    0`                    8`         	           @`                    H`                    P`         
   �@����%"E  h   �0����%E  h   � ����%E  h
E  h   � ����%E  h   ������%�D  h   ������%�D  h   ������%�D  h   ������%�D  h   �����%�D  h   �����%�D  h   �����%�D  h   �����%�D  h   �p����%�D  h   �`����%�D  h   �P����%�D  h   �@����%�D  h   �0����%�D  h   � ����%�D  h   �����%�D  h   � ����%�D  h   ������%zD  h    ������%rD  h!   ������%jD  h"   ������%bD  h#   �����%ZD  h$   �����%RD  h%   �����%JD  h&   �����%BD  h'   �p����%:D  h(   �`����%2D  h)   �P����%*D  h*   �@����%"D  h+   �0����%D  h,   � ����%D  h-   �����%
D  h.   � ����%D  h/   ������%�C  h0   ������%�C  h1   ������%�C  h2   ������%�C  h3   �����%�C  h4   ����H��H��A  H��t��H��Ð��������H��C  H�=�C  UH)�H��H��w]�H�$A  H��t�]��@ H��C  H�=�C  UH)�H��H��H��H��?H�H��H��u]�H�tA  H��t�]��@ �=IC   u'H�=gA   UH��tH�=*C  �
H��H�WpH�W�yH��H)�H����u~Hc�H��H�,�    H�D��A
H��H�WpH�WD�aH��H)�H������   H�GMc�N�,�    N�4��@# tiH�HH�GH�,�N�d��A�VH��H�߁�   �����E@tH��H���B���I�l$LkH�l$L�d$L�t$ L�+H�$L�l$H��(�f�     �[���H�SH���H�3%  �f���fD  H�\$�H�l$�H��L�d$�H��H�OpH�HcH��H�OpH�O�jH��H)�H����uYHc�H��L�$)I�4$�F  � u)H��X  I�$HkL�d$H�+H�$H�l$H���@ �V   ����H��t�H��p  ��H��$  ����fff.�     H�\$�L�d$�H��H�l$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�OD�bH��H)�H������   H�GMc�N�,�    N�4��@# ��   H�PH�GH�,�1�A�F  � uUH�CH��H��N�d��������E@tH��H������I�l$LkH�l$L�d$L�t$ L�+H�$L�l$H��(��    L��H������1҄����@ ����H���z���H�t#  �����    USH��H��H�OpH�HcH��H�OpH�O�jH��H)�H����uHc�H�4��b���H�CH�D��H�H��[]�H�#  �C��� H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�O�jH��H)�H������   H�GHc�L�,�    L�$��@# ��   H�PH�GL�4�A�T$��  � um��H�Cu4H��@  H��LkL�+H�$H�l$L�d$L�l$L�t$ H��(�D  I�T$L��H��H�l���;���A�F@u<L�uLkL�+��    L��H������A�T$�fD  ����I���a��� L��H�������H��!  ����ffffff.�     H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�O�jH��H)�H������   H�GHc�L�,�    L�$��@# ��   H�PH�GL�4�A�T$��  � u}��u8H�CH��@  H��LkL�+H�$H�l$L�d$L�l$L�t$ H��(�D  I�t$1�H������L��H��H������A�F@H�CH�l��u;L�uLkL�+�fD  L��H������A�T$�n��� �����I���Q��� L��H���]����H��   ����ffffff.�     H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H�OpH�HcH��H�OpH�O�jH��H)�H������   H�GHc�L�,�    L�$��@# ��   H�PH�GL�4�A�T$��  � ��   ��tI�t$�Fu9H�CH��@  H��LkL�+H�$H�l$L�d$L�l$L�t$ H��(�fD  �   H���#���L��H��H���U���A�F@H�CH�l��u=L�uLkL�+��     L��H���U���A�T$�b��� �c���I���A��� L��H��������H�,  �_���ffffff.�     H�\$�H�l$�H��L�d$�L�l$�L�t$�L�|$�H��XH�WpH�Hc
H��H�WpH�W�iH��H)�H������  Hc�L�d�L�4�    N�<2A�D$
  H�w@H��(�4�����fW�uH��@
  �H@�*�H�S���Y��,�D�H�H��J�"H�H�H�CJ� I�����H�CK�T>�H��H�H��[]A\A]A^A_�f.�     L��@
  �������I��(L���F���ƃ<  �0���Mc��D  AWAVAUI��ATUSH��8H�GpH�/HcH��H�GpH�GD�rH��H)�H�Mc�H�����D�b(�F  N�<�L��L�t$ H��H�T$(A�W����  ����  ��  ���  �I��P  E1��H*R ���e  H�T$ ��H��   H�T*H��H�T$�   �H�U�B��   E1��   H��L��L���$�W���H���$��  �P����  H�H����  H�RH���  E������t)�E����  H�U�B��  I��A�   fD  H��H;\$I�E��   E��H�,�^����E���D�������   %  �=  �H�E ��  �H*H E��t,A�G���G  %  �=  �I��<  �H*P fD  f.���   E������tf(�I��E1�H��H;\$I�E�b���H�T$ L�<�L�|$(M}M�} H��8[]A\A]A^A_�f.�     I�OA�   �A�O������(�������  I�E1��R(�-���f.�     E�����e���D  ����   H�E �H(����f�     ����  H� fW�f.@(�b����\���E�����W���@ ��t�H� H�x  �����5���E�����0���D  ����   I��P(�����f�����   %  �=  �H�E ��  �H*P I��E1�����f��   H��L���$�����$f(��<���D  H�@ H����   �H*�� �����E������     H��@  J��H�GJ��H�H��8[]A\A]A^A_� ����   H�E I��E1��P(�{��� �   L��L���$�s����$f(������D  H�@ H����   �H*�����f�     H�������H�@�80���������D  �   H��L���$��������$���|���@ H��H��H	��H*��X�����fD  �   H��L�������f(�I��E1�����f�     H�@ H��xW�H*���H��H��H	��H*��X������H�R H��xG�H*�E1������   L��L���`���E1�f(�I�E����H��H��H	��H*��X��r���H�у�H��H	��H*��X��ffffff.�     AWI��AVAUATUSH��8H�WpL�wL�'HcH��H�WpL��PI��H)ÉT$H�����B  HcL$H�L$H��I΃�H�L$I�6�j  H�L$ H�T$(E1��X���H��H���  H� L��L�hH�����I��p  I�w\L�����   �D$�O���A�GXI�wL��A�G\����I��p  ƀ�   I��`  H�PH���R  H��B �����B(   H� H�@    I��X  M+gH� I��L�`H�H�@I�GH�
H�	H�IH��I�O H�
H�	H�IH��I�H�I��`  I��X  �B ;B$��  ���B I��`  HcP L�$�I��L`A�$I�I+GH��A�D$I��P  I�D$I�GpI+GhH��A�D$A�G8A�D$I���  A�D$I�l$(I�D$H�E �@`I�D$     A�D$@H�E �P`���  I�G�@#f%� fA�D$H�U �B`�����B`~H�E L��L���P`�3���I��P  �!   L�������H�E L��HcP`I�EM�nA�   H��I��P  H�@I�GH�E L�`(I���  H�p�;��� I���  I�U L��H�@H�M�gA��8  I�H�0H���e  �F���=  H�H���M  H�@H����  H�U �j`�x  D  I��`  �J Hc���H���J H��HBH�PI��P  HcHI�WhH��I�Wp�PA�W8H�@I�I���  I��`  H�@H���M  I��X  I+WL��H�	H��H�QH�H�RI�WH�H�	H�IH��I�O H�H�	H�IH���L$I�H�I��`  I��p  I��X  ���   �~���Dt$I�GMc�J��H�L$H��L�l$MoM�/H��8[]A\A]A^A_�f.�     ���/  H�H�x  ���������A��I��D9��[���H�U �j`u�E���$  �����E��  I��`  �J Hc���H���J H��HBH�PI��P  HcHI�WhH��I�Wp�PA�W8H�@I�I���  I��`  H�@H����  I��X  I+WL��H�	H��H�QH�H�RI�WH�H�	H�IH��I�O H�H�	H�IH���L$I�H�I��`  I��p  I��X  ���   ����I�GI��@  ����fD  ��tsH�fW�f.@(����������H�U �j`������E���  �����E�t���H��L��������d���@ H�������H�F�80�7����q���D  �   L���C��������M���f�     H��@  I��I�LoL�/H��8[]A\A]A^A_�D  L��H�$����H�$�B �Z����E�   H��L�����������H��L���L���������    L�������H��I��`  H�BI��`  H�P����H��L���o��������H��L���_����j���H�U  �n���H�=T  1�����I���  H��t�x	t&L�������H�5G  H��1��%����   L�������H�@H�@H��t�H� H�@(H��u��ffff.�     AWAVI��AUATUSH��HH�GpL�/HcH��M��H�GpH�G�JH��I)�I��E��D�|$�  Hc�H�L$H�T$H��H�L$ L�$��{���H�l$ InH�Ã|$�  H�L$0H�T$8E1�L��L���<���H��I����  H� L��H�@HH�D$�����I��p  I�v\L�����   �D$/�.���A�FXI�vL��A�F\�z���I��p  ƀ�   I��`  H�PH���  H��B �����B(   H� H�@    I��X  M+nH� I��L�hH�H�@I�FH�
H�	H�IH��I�N H�
H�	H�IH��I�H�I��`  I��X  �B ;B$�;  ���B I��`  HcP L�,�I��LhA�E I�I+FH��A�EI��P  I�EI�FpI+FhH��A�EA�F8A�EI���  A�EM�e(I�EI�$�@`I�E     A�E@I�$�H`����  I�F�@#f%� fA�EI�$�B`�����B`~I�$H�t$L���P`����I��P  �!   L�������I�$H�L$H�5�  L��HcP`H�A�   H�к   I��P  H�@I�FI�$H�@(H�D$�<���H�5p  �   �   L��H�$����L�$I��L��I�p�����I�uL�������L�$I�@H�H�UH9�t�   H��L�������|$tZA��N�<�   L�|$E1��I�EJ�T=L��H�H�D$I�FA��8  I�H�H9�t�   H��L���F���I��L;|$u�I�$�j`uA�D$���d  ����A�D$�  I��`  �J Hc���H���J H��HBH�PI��P  HcHI�VhH��I�Vp�PA�V8H�@I�I���  I��`  H�@H���s  I��X  I+VL��H�	H��H�QH�H�RI�VH�H�	H�IH��I�N H�H�	H�IH��I�H�I��`  I��p  I��X  �T$/���   �����I�FH�L$H��H�D$ IFI�H��H[]A\A]A^A_�f.�     I��@  H�E H�D$ IFI�H��H[]A\A]A^A_�f.�     L��H�$�����H�$�B �����     L��L�����������A�D$�   L��L���*�������L��L���j����q�����    L������H��I��`  H�BI��`  H�P�����H��	  ����H�=�	  1������I���  H��t�x	t&L���$���H�5�	  H��1��c����   L������H�@H�@H��t�H� H�@(H��u��ff.�     AWAVAUATI��USH��H�GpH�HcH��H�GpH�GH�6�yH��D�n(H)�H������   Hc�A��H�4�    H�t$Hƃ�H�.~S��H��   L�tI����    I�D$L�<H��   L��L�������D9�ID�H��L9�u�H�t$It$H�.L�|$M|$M�<$H��[]A\A]A^A_�f.�     I��$@  Hc�H��I�D$H��I�$H��[]A\A]A^A_�D  AWAVAUATUH��SH��8H�GpL�/HcH��H�GpH�GD�rH��I)�Mc�I��E��D���  J�4�J��    H�T$(�F��tH�V�B�  ����   %  �=  �H��P  �H*@ �D$ E1����  A��J��   O�l.I���8f�     A�   �   L��L��H���G���H���  H��L9��Q  H�EM��L�<u�A�G���g  I�W�B�Y  H��������D$ H��H��I������� ��t{H�E1��@(�D$ �D���D  H��@  J��H�GJ��H�H��8[]A\A]A^A_� H�t$����H�t$�   H��I��H��H���+���fW��D$ �����@ �   H��E1��x����D$ �����D  H�@ H���q  �H*��D$ ���� A�D$
   H������H��  E1��$    A�0   �   H��H��I�������L� A�|$	t!H�
 a b v5.14.0 1.23 ListUtil.c List::Util::max List::Util::min List::Util::sum List::Util::minstr List::Util::maxstr &@ List::Util::reduce List::Util::first List::Util::shuffle $$ Scalar::Util::dualvar Scalar::Util::blessed Scalar::Util::reftype Scalar::Util::refaddr Scalar::Util::weaken Scalar::Util::isweak Scalar::Util::readonly Scalar::Util::tainted Scalar::Util::isvstring &$ Scalar::Util::set_prototype List::Util REAL_MULTICALL       set_prototype: not a subroutine reference       set_prototype: not a reference  Scalar::Util::looks_like_number ;�      p����   �����   @���    ���8  p���`  `����  ����   ����  ����  ����0  ���X  p����  P����  p���   ����h  �����  ����8  �����  ���              zR x�  $      ����`   FJw� ?;*3$"       D   ����p    k   4   \   8����    A�A�G s
AABQ
AAA $   �   ����e   J��V0����
H  $   �   ����    J��V0����
J  $   �   �����    J��L �e
E      $     X���	   J��V0����
H  ,   4  @���]    A�A�G E
AAA     $   d  p���1   J��V0����
F  $   �  ����A   J��V0����
F  $   �  ����Q   J��V0����
G  ,   �  �����   J��[`����N
E       L     ����   B�B�B �B(�A0�A8�G@�
8A0A(B BBBK     d   \  h���A   B�B�B �E(�A0�A8�Dp

8A0A(B BBBKz
8A0A(B BBBD  d   �  P����   B�E�B �B(�A0�A8�Dp�
8A0A(B BBBK�
8A0A(B BBBF  d   ,  �����   B�B�E �B(�A0�A8�D�j
8A0A(B BBBK[
8A0A(B BBBK   \   �  @���   B�B�B �B(�D0�A8�DP�
8A0A(B BBBK`8A0A(B BBBd   �  ����v   B�B�B �B(�A0�D8�Dpa
8A0A(B BBBD�
8A0A(B BBBD   L   \  ���f   B�G�B �B(�A0�A8�G`*
8A0A(B BBBF                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    �      `                     \             `      
       �                           �_             �                           h                          X      	              ���o    �      ���o           ���o    J      ���o                                                                                                                                                                                                                                                                           h]                      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �a      Util.so �-9� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                  �      �      $                              "             �      �      \                              ���o       P      P      �                             (                         �                          0             �      �      �                             8   ���o       J      J      �                            E   ���o       �      �                                   T                         X                           ^             h      h      �                          h             `      `                                    c             p      p      `                            n             �      �      �)                             t             xG      xG      	                              z      2       �G      �G      x                            �              J       J      �                              �             �J      �J      �                             �             P]      P]                                    �             X]      X]                                    �             `]      `]                                    �             h]      h]      �                           �             8_      8_      �                             �             �_      �_      �                            �             �a      �a                                    �             �a      �a                                    �                      �a                                                          �a      �                              FILE   #560b8084/auto/MIME/Base64/Base64.so  8pELF          >           @       �1          @ 8  @                                 �*      �*                    �-      �-      �-                                 �-      �-      �-      �      �                   �      �      �      $       $              P�td   @(      @(      @(      L       L              Q�td                                                  R�td   �-      �-      �-      `      `                      GNU ��0��IKP�ӑ���T�    %   )                 	      (   "                                   
      $      !               
 x              �                     �                                            l                     G                     �                                           ^                     �                     �                                           �                                             �                      �                      �                     �                     �                     �                     -                     �                     �                      a                       8                                            R   "                   9                     (    p      +      �   ���0              �     @      %      �   ���0              q     $      �      �    �      	      �   ���0                  
 x                  
           @0                    H0                    P0                    X0                    `0                    h0                    p0                    x0                    �0                    �0                    �0                    �0                    �0                    �0                    H���  H���          �5Z!  �%\!  @ �%Z!  h    ������%R!  h   ������%J!  h   ������%B!  h   �����%:!  h   �����%2!  h   �����%*!  h   �����%"!  h   �p����%!  h   �`����%!  h	   �P����%
!  h
   �@����%!  h   �0����%�   h   � ����%�   h
H��H�WpH�WD�IH��H)�H������  Ic�H��H��    H�D$�A%   =   �Z  H�T$H������H�t$H��H��L�,3�   HD�L���M����H D  L9�I��L�`��   �1���    H��HD�H��I9�vs�<	t�< t�<
 ��   H��t5H9�f�v.H��L���     D�H��D�H��H9�u�H��H)�I��<=��   A�$I��H��1�I9�w�H��L��H��t%H9�v D  �H��A�$I��H9�u�H)�L�$2A�$ M+gL��I�L�`I�FL�<�I�FH�4��-���H�l$InI�.H��([]A\A]A^A_�f�H�SI9��)����{
����H�Ӹ
   �����@ A�$
H��I��1������@ H�CI9�wgH�SI9��  �CH��< t��   f.�     �<	��   H��L9�u�H�CI9�v	�;
�H���H�CI9��Q����C����{
�B���H��1�����<	�������    H������H��  ����fff.�     AVAUI��ATUSH�� H�WpdH�%(   H�D$1�H�Hc
H��H�WpH�WD�qH��H)�H������  Mc�J�4�J�,�    �F
����H D  L9�H�x�c  L�O  A�����f�     1�fD  �H��A����t
Hc���L4L9���   ��~��L$���t^�T$���tT�0   ��!���	��L$�����   �<   ��!���	�W�T$�����   ��	шOH��I9��g���H��H+HH�H�J� L��I�UJ��I�EJ�4������ImH�D$dH3%(   I�m ��   H�� []A\A]A^�D  ���8�����~����T$�D$�ADшT$����H�T$�   �	���H��H�D$����H���\���H��H��H+H�S���1��L���H��  ���������ff.�     AWAVAUATI��USH��hH�GpH�HcH��H�GpH�G�JH��H)�H������  Hc�H�L$H�T$H��H�L$HH��1ҋHH��H�D$ ��    �L$@�������t&I�D$H�L$H�T�H�2�F<�9  ����A  H��  H�D$P   H�D$���D$D    ~>I�D$H�T$H�t�H��t*�F����  H�H��tH�@H����  �D$D   H�T$ �B
�+  H�|$P �  I��H�  I��IL�{uM9�v�{
�m  @ H�>
�����I9����������@ L�{I���L��� H�L$PH��t�t$D�������I���<  H�T$A�   H��L�������L�{E1��"���fD  �K   L)�I9��C���L�t$0L�t$H�\$8H��D  H��L��A�   H��L��I)�����H��  A�   �   H��L��I��v���H�L$PA�   L��H��L��K   �X���I��Kw�E1�M��L�t$0H�\$8�����L9������H�E H�x tH�|$P ��   �D$@��tH�t$ 1ɺ   L������I�D$H�T$L��H�,�I�D$H�4������H�D$HID$I�$H��h[]A\A]A^A_�H�E H�QH�@H9������H�uH��H)�H�T��:=������D��H�E H�h����H�N�A �  ��������  H�H�@H�D$PH�H�@H�D$����M���&���H�h
  H��L��A�   �   �%���H�L$PH�T$A�   H��L���
��������H�t$ H�T$X�   L���^���H�D$(H�D$X������uB����   H�fW��   f.B(z�����D$D�]����L$DA�L   �����������H�1�H�x  ���L$D�0���H���'���H�F�80��������H�T$P�   L�������H�D$�����   L���.����������y���H�O	  ����D  AWAVAUATI��USH��HH�GpL�?HcH��H�GpH�GD�BH��I)�I��E����  Mc�N�4�J��    H�T$(1�A�NL����    �L$$�����A�F
H��H�t$8���������f�H�N�A �  �/�����tIH�H�@H�D$0H�L�P�"���f�H�T$8�   L��L�������L�L$8H��������D$    ����H�T$0�   L��L�L$����L�L$I�������H�K  ����H�D$8�����    AWAVAUI��ATUSH��H�OpH�HcH��H�OpH�OD�rH��H)�H�����  Mc�J�4�J�,�    �F
  L��  H�
  L�  H�
  L�9  H�
  L�  H�
  L��   H�
 sv, ... = =%02X v5.14.0 3.13 $;$ Base64.c MIME::Base64::encode_base64 MIME::Base64::decode_base64 $;$$ MIME::QuotedPrint::encode_qp MIME::QuotedPrint::decode_qp   MIME::Base64::encoded_base64_length     MIME::Base64::decoded_base64_length             ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/                                �������������������������������������������>���?456789:;<=������� 	

8A0A(B BBBC    D   �   ���%   B�B�E �A(�A0�DP�
0A(A BBBF    L   �    ���+   B�B�B �B(�D0�A8�D�p
8A0A(B BBBA   L   ,  ����	   B�B�B �B(�D0�A8�D�
8A0A(B BBBD   L   |  ����\   B�B�B �E(�A0�A8�DP
8A0A(B BBBD    ,   �  �����   J��[P����0
K       $   �  p����   Y����QP���                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  �      �                     �             x      
                                  �/                                        h                           h      	              ���o    �
      ���o           ���o    z
      ���o                                                                                                                                                                                           �-                      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �      �0      Base64.so   $B .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                              �      �      $                              "             �      �      @                              ���o       0      0      \                             (             �      �      �                          0             h      h                                   8   ���o       z
      z
      R                            E   ���o       �
      �
      0                            T                           h                           ^             h      h                                h             x      x                                    c             �      �      p                            n                           �                             t             �%      �%      	                              z             �%      �%      `                              �             @(      @(      L                              �             �(      �(      $                             �             �-      �-                                    �             �-      �-                                    �             �-      �-                                    �             �-      �-      �                           �             �/      �/      `                             �             �/      �/      �                             �             �0      �0                                    �             �0      �0                                    �                      �0                                                          �0      �                              FILE   %af712be3/auto/PerlIO/scalar/scalar.so  9�ELF          >    �      @       �2          @ 8  @                                 �'      �'                    �-      �-      �-      8      @                    �-      �-      �-      �      �                   �      �      �      $       $              P�td   $      $      $      �       �              Q�td                                                  R�td   �-      �-      �-      8      8                      GNU g	�^]�A�6�� \ :��Dh     %   C      #          <      
   -      %   )      8   +   /   '         >   .      	                !   &       9   (   $          A   0                                                                  @   ;       B             *              ?   =           2                      6      7                       3   :         4       
 �              q                     �                     �                     N                     �                                             ;                     �                     L                     �                     �                                          3                     /                     q                     �                      �                     �                     G                     �                     �                                                                                      '                     �                     T                                          )                                          t                                                               a                       �                     x                     8                       �                     R   "                   �                         
 �              �    �      K      *   �� 2              �     1      �       6   ��2              �    @      �       #   �� 2              �                   �    �      S       \    P      D       �           �      �                  �     �             �     �             �    �             �    �             @    �"      �       u     �             �    �      G       �    �      2       5    @      �        __gmon_start__ _init _fini _ITM_deregisterTMCloneTable _ITM_registerTMCloneTable __cxa_finalize _Jv_RegisterClasses PerlIOScalar_fileno PerlIOScalar_tell PerlIOScalar_fill PerlIOScalar_flush PerlIOScalar_dup PerlIOBase_dup PerlIOScalar_arg Perl_newRV_noinc PerlIO_sv_dup Perl_newSVsv PerlIOScalar_open PerlIO_push PerlIO_arg_fetch PerlIO_allocate PerlIOScalar_set_ptrcnt Perl_mg_get PerlIOScalar_bufsiz PerlIOScalar_get_cnt PerlIOScalar_get_base Perl_sv_2pv_flags PerlIOScalar_get_ptr PerlIOScalar_write Perl_sv_force_normal_flags memmove Perl_sv_grow Perl_mg_set PerlIOScalar_read memcpy __errno_location PerlIOScalar_seek memset Perl_ckwarn Perl_warner PerlIOScalar_close PerlIOBase_close PerlIOScalar_popped Perl_sv_free Perl_sv_free2 PerlIOScalar_pushed Perl_newSVpvn PerlIOBase_pushed Perl_sv_upgrade Perl_get_sv PL_no_modify boot_PerlIO__scalar Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck PerlIO_scalar PerlIO_define_layer Perl_call_list PerlIOBase_binmode PerlIOBase_eof PerlIOBase_error PerlIOBase_clearerr PerlIOBase_setlinebuf libc.so.6 _edata __bss_start _end GLIBC_2.2.5                                                                                                                       ui	   ;      �-             �      �-             `       1              1      (1             $      �/                    �/         1           �/                    �/                    �/         #           �/         &           �/         (           @1         8           H1         @           P1         -           X1                    `1         ,           h1         ?           p1         9           x1         B           �1         /           �1         +           �1         :           �1         <           �1         5           �1         ;           �1         )           �1                    �1                    �1                    �1         3           �1         A           �1         =           �1         6           �1         7            0                    0                    0                    0                     0                    (0                    00         	           80         
           @0                    H0         
  h   ������%  h   �����%�  h   �����%�  h   �����%�  h   �����%�  h   �p����%�  h   �`����%�  h	   �P����%�  h
   �@����%�  h   �0����%�  h   � ����%�  h
H�H�@[Ð����H�s H�H�@��fffff.�     SH��Ct&H�s �F u$H�H�S(H�@H9�vH)�[��    1�[�@ �C���H�s H�S(H�H�@H9�w���ffff.�     H�\$�H�l$�H��H��CtYH�s H���F�    u��t$H�FH�\$H�l$H��������H�s �F��u�H��H�\$H�l$�   1�H������f�1�H�\$H�l$H���ffffff.�     SH�1��Ct	����HC([�f�     L�l$�H�\$�1�H�l$�L�d$�I��L�t$�L�|$�H��8H�.�E��   H�] I��I��I���C ��   1�H��L�������I�E �@ t~H�H�HI�H9P��   H�CH�<H�U(L��L�������H�H�U(H;PvH�P�C��D�  @ �SuoL��H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8�f�     H�M(H�I�H;Pv�H;Pv�H��L�������H�M(I��l����H���X����.��� H��L���5���� H��L�������H�H�JI��0���D  H����   H�\$�H�l$�L�d$�L�l$�H��8H��C��tlH�s I��I���F
NL
LL   $   �   �����    J��Q@��b
C         p���D    N ��u        4  ����2    A�]
B    $   T  ����S    A�g
HC
E      $   |  �����    N ��q
Ai
GP    �  `���    A�U       $   �  `���K   V����Q@���
J,   �  �����    a@����q
����Fx����  $     8���z   J��Q@��o
F       D  ����    A�S          d  ����G    A�h
G    $   �  �����   J��M��L0��
J $   �  x����    Y����QP���                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   �      `                                  �      
             p      
       G                           �/             �                           �             �             0      	              ���o    �      ���o           ���o           ���o                                                                                                                                                   �-                      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �               1                              �       $      0                                                                                                                                                                                                              scalar.so   R�_� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                              �      �      $                              "             �      �      �                              ���o       �      �      �                             (             p      p      H                          0             �
      �
      G                             8   ���o                     �                            E   ���o       �      �                                   T             �      �      0                           ^             �      �      �                          h             �      �                                    c             �      �                                   n             �      �                                   t             �#      �#      	                              z      2       �#      �#      0                             �             $      $      �                              �             �$      �$      �                             �             �-      �-                                    �             �-      �-                                    �             �-      �-                                    �             �-      �-      �                           �             �/      �/      8                             �             �/      �/                                  �              1       1                                     �              2       2                                    �                       2                                                          2      �                              FILE   303004cf4/auto/Tie/Hash/NamedCapture/NamedCapture.so  8�ELF          >    �      @       �1          @ 8  @                                 ,      ,                    �-      �-      �-                                �-      �-      �-      �      �                   �      �      �      $       $              P�td   X      X      X      D       D              Q�td                                                  R�td   �-      �-      �-      H      H                      GNU j�������Z���̖�Io    %   (                      	          
   !   #                                                                                   '                                                          "                          �� CH
 �
 �
           @0                    H0                    P0                    X0                    `0                    h0                    p0                    x0                    �0                    �0                    �0                    �0                    �0                    �0                    �0                    �0                    H���  H���  �5�!  �%�!  @ �%�!  h    ������%�!  h   ������%�!  h   ������%�!  h   �����%�!  h   �����%�!  h   �����%�!  h   �����%�!  h   �p����%�!  h   �`����%�!  h	   �P����%�!  h
   �@����%�!  h   �0����%�!  h   � ����%�!  h
  H�,��}t1��t#A��uA�   A��   �%H�  H�������A����   A�   A�@   Mc�J�4�    H�H����   H�:�G
  L�,�A�}t\����A9��s  fD  ��   ��  H��@  Hc�H��H�CH��H�H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8É���A9��  Lc�J���B
H  $   l   p����    A�A�G �AA,   �   �����   J��[P����F
E       $   �   x���&   J��[@�����
AL   �   ����4   B�B�B �B(�A0�A8�G`p
8A0A(B BBBE    L   <  p���V   B�Q�B �B(�A0�A8�GP+8A0A(B BBB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       P                           �             �
       �                           �/             @                           �             �
                    	              ���o    `
      ���o           ���o    

      ���o                                                                                                                                                                   �-                                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �0      NamedCapture.so _v�	 .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                  �      �      $                              "             �      �      <                              ���o       0      0      L                             (             �      �      �                          0             @      @      �                             8   ���o       

      

      P                            E   ���o       `
      `
                                   T             �
      �
                                  ^             �      �      @                          h             �
                                             	                    
 �              �                     @                                            �                      �                      s                     l                                            �                      ,                     �                     �                     �                     �                     �                      �                     �                      a                                            8                       R   "                   �                         ���                   �      �         ���               u     �
 �                  
           8                     @                     H          
  h   �����%  h   �����%�  h   �����%�  h   �p����%�  h   �`����%�  h	   �P����%�  h
   �@����%�  h   �0����%�  h   � ����%�  h
�x	��   H�B H���m����@u�1�1�H��H�������S��� H�t$�&���H�t$H�������f�     H�J�A �  �����H�  H���@���H�
H��t���HcI�b���H�H���V���1��@ �� �  �� �  �����H�PH�������H�R8H��t5H�H�x( �����H��H� H�@(�6��� H� H�@(H���#�������H�H�z( uҐ�{���ff.�     H�\$�H�l$�H��L�d$�L�l$�H��(H�WpH�/HcH��H��H�WpH�W�xH��H)�H��H��Hc�H��H)̓���   Hc�H���B<��   �����   ����   H�B�x
H��H�WpH�W�yH��H)�H����A����  Hc�H��H�|$H�;�O����  �����  ����  A��L�gH�L$uH�D��H�E H��8[]A\A]A^A_�@ L�|���E1�I�D�H�D$�d�I�I�~H�@H�D$(�?-�D$u
H�l$(H��A�|$
H <   l   ����5   B�B�A �A(�G@�
(A ABBF     $   �   �����   J��Q0���
G    d   �   P���A   B�B�B �B(�A0�D8�Dpx
8A0A(B BBBE�
8A0A(B BBBG    $   <  8���p   Y����QP��E                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  �
       0                           �             �                            
             �                    	              ���o    �      ���o           ���o    x      ���o                                                                                                                                                                   �                      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �       attributes.so   �g�� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .init_array .fini_array .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                  �      �      $                              "             �      �      �                               ���o       �      �      L                             (                         0                          0             H      H      0                             8   ���o       x      x      D                            E   ���o       �      �                                   T             �      �                                  ^              
       
      �                          h             �      �                                    c             �      �      0                            n             �      �      �	                             t             �      �      	                              z      2       �      �      �                             �             �      �      <                              �             �      �      d                             �             �      �                                    �             �      �                                    �             �      �                                    �             �      �      �                           �             �      �      H                             �             �      �      �                             �             �       �                                     �             �       �                                     �                      �                                                           �       �                              FILE   55b87960/lib.pm  	#line 1 "/usr/lib/perl/5.14/lib.pm"
package lib;

# THIS FILE IS AUTOMATICALLY GENERATED FROM lib_pm.PL.
# ANY CHANGES TO THIS FILE WILL BE OVERWRITTEN BY THE NEXT PERL BUILD.

use Config;

use strict;

my $archname         = $Config{archname};
my $version          = $Config{version};
my @inc_version_list = reverse split / /, $Config{inc_version_list};

our @ORIG_INC = @INC;	# take a handy copy of 'original' value
our $VERSION = '0.63';

sub import {
    shift;

    my %names;
    foreach (reverse @_) {
	my $path = $_;		# we'll be modifying it, so break the alias
	if ($path eq '') {
	    require Carp;
	    Carp::carp("Empty compile time value given to use lib");
	}

	if ($path !~ /\.par$/i && -e $path && ! -d _) {
	    require Carp;
	    Carp::carp("Parameter to use lib must be directory, not file");
	}
	unshift(@INC, $path);
	# Add any previous version directories we found at configure time
	foreach my $incver (@inc_version_list)
	{
	    my $dir = "$path/$incver";
	    unshift(@INC, $dir) if -d $dir;
	}
	# Put a corresponding archlib directory in front of $path if it
	# looks like $path has an archlib directory below it.
	my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir)
	    = _get_dirs($path);
	unshift(@INC, $arch_dir)         if -d $arch_auto_dir;
	unshift(@INC, $version_dir)      if -d $version_dir;
	unshift(@INC, $version_arch_dir) if -d $version_arch_dir;
    }

    # remove trailing duplicates
    @INC = grep { ++$names{$_} == 1 } @INC;
    return;
}

sub unimport {
    shift;

    my %names;
    foreach my $path (@_) {
	my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir)
	    = _get_dirs($path);
	++$names{$path};
	++$names{$arch_dir}         if -d $arch_auto_dir;
	++$names{$version_dir}      if -d $version_dir;
	++$names{$version_arch_dir} if -d $version_arch_dir;
    }

    # Remove ALL instances of each named directory.
    @INC = grep { !exists $names{$_} } @INC;
    return;
}

sub _get_dirs {
    my($dir) = @_;
    my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir);

    $arch_auto_dir    = "$dir/$archname/auto";
    $arch_dir         = "$dir/$archname";
    $version_dir      = "$dir/$version";
    $version_arch_dir = "$dir/$version/$archname";

    return($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir);
}

1;
__END__

FILE   1d366cbd/AutoLoader.pm  \#line 1 "/usr/share/perl/5.14/AutoLoader.pm"
package AutoLoader;

use strict;
use 5.006_001;

our($VERSION, $AUTOLOAD);

my $is_dosish;
my $is_epoc;
my $is_vms;
my $is_macos;

BEGIN {
    $is_dosish = $^O eq 'cygwin' || $^O eq 'dos' || $^O eq 'os2' || $^O eq 'MSWin32' || $^O eq 'NetWare';
    $is_epoc = $^O eq 'epoc';
    $is_vms = $^O eq 'VMS';
    $is_macos = $^O eq 'MacOS';
    $VERSION = '5.71';
}

AUTOLOAD {
    my $sub = $AUTOLOAD;
    my $filename = AutoLoader::find_filename( $sub );

    my $save = $@;
    local $!; # Do not munge the value. 
    eval { local $SIG{__DIE__}; require $filename };
    if ($@) {
	if (substr($sub,-9) eq '::DESTROY') {
	    no strict 'refs';
	    *$sub = sub {};
	    $@ = undef;
	} elsif ($@ =~ /^Can't locate/) {
	    # The load might just have failed because the filename was too
	    # long for some old SVR3 systems which treat long names as errors.
	    # If we can successfully truncate a long name then it's worth a go.
	    # There is a slight risk that we could pick up the wrong file here
	    # but autosplit should have warned about that when splitting.
	    if ($filename =~ s/(\w{12,})\.al$/substr($1,0,11).".al"/e){
		eval { local $SIG{__DIE__}; require $filename };
	    }
	}
	if ($@){
	    $@ =~ s/ at .*\n//;
	    my $error = $@;
	    require Carp;
	    Carp::croak($error);
	}
    }
    $@ = $save;
    goto &$sub;
}

sub find_filename {
    my $sub = shift;
    my $filename;
    # Braces used to preserve $1 et al.
    {
	# Try to find the autoloaded file from the package-qualified
	# name of the sub. e.g., if the sub needed is
	# Getopt::Long::GetOptions(), then $INC{Getopt/Long.pm} is
	# something like '/usr/lib/perl5/Getopt/Long.pm', and the
	# autoload file is '/usr/lib/perl5/auto/Getopt/Long/GetOptions.al'.
	#
	# However, if @INC is a relative path, this might not work.  If,
	# for example, @INC = ('lib'), then $INC{Getopt/Long.pm} is
	# 'lib/Getopt/Long.pm', and we want to require
	# 'auto/Getopt/Long/GetOptions.al' (without the leading 'lib').
	# In this case, we simple prepend the 'auto/' and let the
	# C<require> take care of the searching for us.

	my ($pkg,$func) = ($sub =~ /(.*)::([^:]+)$/);
	$pkg =~ s#::#/#g;
	if (defined($filename = $INC{"$pkg.pm"})) {
	    if ($is_macos) {
		$pkg =~ tr#/#:#;
		$filename = undef
		  unless $filename =~ s#^(.*)$pkg\.pm\z#$1auto:$pkg:$func.al#s;
	    } else {
		$filename = undef
		  unless $filename =~ s#^(.*)$pkg\.pm\z#$1auto/$pkg/$func.al#s;
	    }

	    # if the file exists, then make sure that it is a
	    # a fully anchored path (i.e either '/usr/lib/auto/foo/bar.al',
	    # or './lib/auto/foo/bar.al'.  This avoids C<require> searching
	    # (and failing) to find the 'lib/auto/foo/bar.al' because it
	    # looked for 'lib/lib/auto/foo/bar.al', given @INC = ('lib').

	    if (defined $filename and -r $filename) {
		unless ($filename =~ m|^/|s) {
		    if ($is_dosish) {
			unless ($filename =~ m{^([a-z]:)?[\\/]}is) {
			    if ($^O ne 'NetWare') {
				$filename = "./$filename";
			    } else {
				$filename = "$filename";
			    }
			}
		    }
		    elsif ($is_epoc) {
			unless ($filename =~ m{^([a-z?]:)?[\\/]}is) {
			     $filename = "./$filename";
			}
		    }
		    elsif ($is_vms) {
			# XXX todo by VMSmiths
			$filename = "./$filename";
		    }
		    elsif (!$is_macos) {
			$filename = "./$filename";
		    }
		}
	    }
	    else {
		$filename = undef;
	    }
	}
	unless (defined $filename) {
	    # let C<require> do the searching
	    $filename = "auto/$sub.al";
	    $filename =~ s#::#/#g;
	}
    }
    return $filename;
}

sub import {
    my $pkg = shift;
    my $callpkg = caller;

    #
    # Export symbols, but not by accident of inheritance.
    #

    if ($pkg eq 'AutoLoader') {
	if ( @_ and $_[0] =~ /^&?AUTOLOAD$/ ) {
	    no strict 'refs';
	    *{ $callpkg . '::AUTOLOAD' } = \&AUTOLOAD;
	}
    }

    #
    # Try to find the autosplit index file.  Eg., if the call package
    # is POSIX, then $INC{POSIX.pm} is something like
    # '/usr/local/lib/perl5/POSIX.pm', and the autosplit index file is in
    # '/usr/local/lib/perl5/auto/POSIX/autosplit.ix', so we require that.
    #
    # However, if @INC is a relative path, this might not work.  If,
    # for example, @INC = ('lib'), then
    # $INC{POSIX.pm} is 'lib/POSIX.pm', and we want to require
    # 'auto/POSIX/autosplit.ix' (without the leading 'lib').
    #

    (my $calldir = $callpkg) =~ s#::#/#g;
    my $path = $INC{$calldir . '.pm'};
    if (defined($path)) {
	# Try absolute path name, but only eval it if the
        # transformation from module path to autosplit.ix path
        # succeeded!
	my $replaced_okay;
	if ($is_macos) {
	    (my $malldir = $calldir) =~ tr#/#:#;
	    $replaced_okay = ($path =~ s#^(.*)$malldir\.pm\z#$1auto:$malldir:autosplit.ix#s);
	} else {
	    $replaced_okay = ($path =~ s#^(.*)$calldir\.pm\z#$1auto/$calldir/autosplit.ix#);
	}

	eval { require $path; } if $replaced_okay;
	# If that failed, try relative path with normal @INC searching.
	if (!$replaced_okay or $@) {
	    $path ="auto/$calldir/autosplit.ix";
	    eval { require $path; };
	}
	if ($@) {
	    my $error = $@;
	    require Carp;
	    Carp::carp($error);
	}
    } 
}

sub unimport {
    my $callpkg = caller;

    no strict 'refs';

    for my $exported (qw( AUTOLOAD )) {
	my $symname = $callpkg . '::' . $exported;
	undef *{ $symname } if \&{ $symname } == \&{ $exported };
	*{ $symname } = \&{ $symname };
    }
}

1;

__END__

FILE   2030bb71/Carp.pm  '�#line 1 "/usr/share/perl/5.14/Carp.pm"
package Carp;

use strict;
use warnings;

our $VERSION = '1.20';

our $MaxEvalLen = 0;
our $Verbose    = 0;
our $CarpLevel  = 0;
our $MaxArgLen  = 64;    # How much of each argument to print. 0 = all.
our $MaxArgNums = 8;     # How many arguments to print. 0 = all.

require Exporter;
our @ISA       = ('Exporter');
our @EXPORT    = qw(confess croak carp);
our @EXPORT_OK = qw(cluck verbose longmess shortmess);
our @EXPORT_FAIL = qw(verbose);    # hook to enable verbose mode

# The members of %Internal are packages that are internal to perl.
# Carp will not report errors from within these packages if it
# can.  The members of %CarpInternal are internal to Perl's warning
# system.  Carp will not report errors from within these packages
# either, and will not report calls *to* these packages for carp and
# croak.  They replace $CarpLevel, which is deprecated.    The
# $Max(EvalLen|(Arg(Len|Nums)) variables are used to specify how the eval
# text and function arguments should be formatted when printed.

our %CarpInternal;
our %Internal;

# disable these by default, so they can live w/o require Carp
$CarpInternal{Carp}++;
$CarpInternal{warnings}++;
$Internal{Exporter}++;
$Internal{'Exporter::Heavy'}++;

# if the caller specifies verbose usage ("perl -MCarp=verbose script.pl")
# then the following method will be called by the Exporter which knows
# to do this thanks to @EXPORT_FAIL, above.  $_[1] will contain the word
# 'verbose'.

sub export_fail { shift; $Verbose = shift if $_[0] eq 'verbose'; @_ }

sub _cgc {
    no strict 'refs';
    return \&{"CORE::GLOBAL::caller"} if defined &{"CORE::GLOBAL::caller"};
    return;
}

sub longmess {
    # Icky backwards compatibility wrapper. :-(
    #
    # The story is that the original implementation hard-coded the
    # number of call levels to go back, so calls to longmess were off
    # by one.  Other code began calling longmess and expecting this
    # behaviour, so the replacement has to emulate that behaviour.
    my $cgc = _cgc();
    my $call_pack = $cgc ? $cgc->() : caller();
    if ( $Internal{$call_pack} or $CarpInternal{$call_pack} ) {
        return longmess_heavy(@_);
    }
    else {
        local $CarpLevel = $CarpLevel + 1;
        return longmess_heavy(@_);
    }
}

our @CARP_NOT;

sub shortmess {
    my $cgc = _cgc();

    # Icky backwards compatibility wrapper. :-(
    local @CARP_NOT = $cgc ? $cgc->() : caller();
    shortmess_heavy(@_);
}

sub croak   { die shortmess @_ }
sub confess { die longmess @_ }
sub carp    { warn shortmess @_ }
sub cluck   { warn longmess @_ }

sub caller_info {
    my $i = shift(@_) + 1;
    my %call_info;
    my $cgc = _cgc();
    {
        package DB;
        @DB::args = \$i;    # A sentinel, which no-one else has the address of
        @call_info{
            qw(pack file line sub has_args wantarray evaltext is_require) }
            = $cgc ? $cgc->($i) : caller($i);
    }

    unless ( defined $call_info{pack} ) {
        return ();
    }

    my $sub_name = Carp::get_subname( \%call_info );
    if ( $call_info{has_args} ) {
        my @args;
        if (   @DB::args == 1
            && ref $DB::args[0] eq ref \$i
            && $DB::args[0] == \$i ) {
            @DB::args = ();    # Don't let anyone see the address of $i
            local $@;
            my $where = eval {
                my $func    = $cgc or return '';
                my $gv      = B::svref_2object($func)->GV;
                my $package = $gv->STASH->NAME;
                my $subname = $gv->NAME;
                return unless defined $package && defined $subname;

                # returning CORE::GLOBAL::caller isn't useful for tracing the cause:
                return if $package eq 'CORE::GLOBAL' && $subname eq 'caller';
                " in &${package}::$subname";
            } // '';
            @args
                = "** Incomplete caller override detected$where; \@DB::args were not set **";
        }
        else {
            @args = map { Carp::format_arg($_) } @DB::args;
        }
        if ( $MaxArgNums and @args > $MaxArgNums )
        {    # More than we want to show?
            $#args = $MaxArgNums;
            push @args, '...';
        }

        # Push the args onto the subroutine
        $sub_name .= '(' . join( ', ', @args ) . ')';
    }
    $call_info{sub_name} = $sub_name;
    return wantarray() ? %call_info : \%call_info;
}

# Transform an argument to a function into a string.
sub format_arg {
    my $arg = shift;
    if ( ref($arg) ) {
        $arg = defined($overload::VERSION) ? overload::StrVal($arg) : "$arg";
    }
    if ( defined($arg) ) {
        $arg =~ s/'/\\'/g;
        $arg = str_len_trim( $arg, $MaxArgLen );

        # Quote it?
        $arg = "'$arg'" unless $arg =~ /^-?[0-9.]+\z/;
    }                                    # 0-9, not \d, as \d will try to
    else {                               # load Unicode tables
        $arg = 'undef';
    }

    # The following handling of "control chars" is direct from
    # the original code - it is broken on Unicode though.
    # Suggestions?
    utf8::is_utf8($arg)
        or $arg =~ s/([[:cntrl:]]|[[:^ascii:]])/sprintf("\\x{%x}",ord($1))/eg;
    return $arg;
}

# Takes an inheritance cache and a package and returns
# an anon hash of known inheritances and anon array of
# inheritances which consequences have not been figured
# for.
sub get_status {
    my $cache = shift;
    my $pkg   = shift;
    $cache->{$pkg} ||= [ { $pkg => $pkg }, [ trusts_directly($pkg) ] ];
    return @{ $cache->{$pkg} };
}

# Takes the info from caller() and figures out the name of
# the sub/require/eval
sub get_subname {
    my $info = shift;
    if ( defined( $info->{evaltext} ) ) {
        my $eval = $info->{evaltext};
        if ( $info->{is_require} ) {
            return "require $eval";
        }
        else {
            $eval =~ s/([\\\'])/\\$1/g;
            return "eval '" . str_len_trim( $eval, $MaxEvalLen ) . "'";
        }
    }

    return ( $info->{sub} eq '(eval)' ) ? 'eval {...}' : $info->{sub};
}

# Figures out what call (from the point of view of the caller)
# the long error backtrace should start at.
sub long_error_loc {
    my $i;
    my $lvl = $CarpLevel;
    {
        ++$i;
        my $cgc = _cgc();
        my $pkg = $cgc ? $cgc->($i) : caller($i);
        unless ( defined($pkg) ) {

            # This *shouldn't* happen.
            if (%Internal) {
                local %Internal;
                $i = long_error_loc();
                last;
            }
            else {

                # OK, now I am irritated.
                return 2;
            }
        }
        redo if $CarpInternal{$pkg};
        redo unless 0 > --$lvl;
        redo if $Internal{$pkg};
    }
    return $i - 1;
}

sub longmess_heavy {
    return @_ if ref( $_[0] );    # don't break references as exceptions
    my $i = long_error_loc();
    return ret_backtrace( $i, @_ );
}

# Returns a full stack backtrace starting from where it is
# told.
sub ret_backtrace {
    my ( $i, @error ) = @_;
    my $mess;
    my $err = join '', @error;
    $i++;

    my $tid_msg = '';
    if ( defined &threads::tid ) {
        my $tid = threads->tid;
        $tid_msg = " thread $tid" if $tid;
    }

    my %i = caller_info($i);
    $mess = "$err at $i{file} line $i{line}$tid_msg\n";

    while ( my %i = caller_info( ++$i ) ) {
        $mess .= "\t$i{sub_name} called at $i{file} line $i{line}$tid_msg\n";
    }

    return $mess;
}

sub ret_summary {
    my ( $i, @error ) = @_;
    my $err = join '', @error;
    $i++;

    my $tid_msg = '';
    if ( defined &threads::tid ) {
        my $tid = threads->tid;
        $tid_msg = " thread $tid" if $tid;
    }

    my %i = caller_info($i);
    return "$err at $i{file} line $i{line}$tid_msg\n";
}

sub short_error_loc {
    # You have to create your (hash)ref out here, rather than defaulting it
    # inside trusts *on a lexical*, as you want it to persist across calls.
    # (You can default it on $_[2], but that gets messy)
    my $cache = {};
    my $i     = 1;
    my $lvl   = $CarpLevel;
    {
        my $cgc = _cgc();
        my $called = $cgc ? $cgc->($i) : caller($i);
        $i++;
        my $caller = $cgc ? $cgc->($i) : caller($i);

        return 0 unless defined($caller);    # What happened?
        redo if $Internal{$caller};
        redo if $CarpInternal{$caller};
        redo if $CarpInternal{$called};
        redo if trusts( $called, $caller, $cache );
        redo if trusts( $caller, $called, $cache );
        redo unless 0 > --$lvl;
    }
    return $i - 1;
}

sub shortmess_heavy {
    return longmess_heavy(@_) if $Verbose;
    return @_ if ref( $_[0] );    # don't break references as exceptions
    my $i = short_error_loc();
    if ($i) {
        ret_summary( $i, @_ );
    }
    else {
        longmess_heavy(@_);
    }
}

# If a string is too long, trims it with ...
sub str_len_trim {
    my $str = shift;
    my $max = shift || 0;
    if ( 2 < $max and $max < length($str) ) {
        substr( $str, $max - 3 ) = '...';
    }
    return $str;
}

# Takes two packages and an optional cache.  Says whether the
# first inherits from the second.
#
# Recursive versions of this have to work to avoid certain
# possible endless loops, and when following long chains of
# inheritance are less efficient.
sub trusts {
    my $child  = shift;
    my $parent = shift;
    my $cache  = shift;
    my ( $known, $partial ) = get_status( $cache, $child );

    # Figure out consequences until we have an answer
    while ( @$partial and not exists $known->{$parent} ) {
        my $anc = shift @$partial;
        next if exists $known->{$anc};
        $known->{$anc}++;
        my ( $anc_knows, $anc_partial ) = get_status( $cache, $anc );
        my @found = keys %$anc_knows;
        @$known{@found} = ();
        push @$partial, @$anc_partial;
    }
    return exists $known->{$parent};
}

# Takes a package and gives a list of those trusted directly
sub trusts_directly {
    my $class = shift;
    no strict 'refs';
    no warnings 'once';
    return @{"$class\::CARP_NOT"}
        ? @{"$class\::CARP_NOT"}
        : @{"$class\::ISA"};
}

1;

__END__

FILE   90004ccc/Carp/Heavy.pm  N#line 1 "/usr/share/perl/5.14/Carp/Heavy.pm"
package Carp;

# On one line so MakeMaker will see it.
use Carp;  our $VERSION = $Carp::VERSION;

1;

# Most of the machinery of Carp used to be there.
# It has been moved in Carp.pm now, but this placeholder remains for
# the benefit of modules that like to preload Carp::Heavy directly.
FILE   7a62b3b9/Compress/Zlib.pm  8�#line 1 "/usr/share/perl/5.14/Compress/Zlib.pm"

package Compress::Zlib;

require 5.004 ;
require Exporter;
use Carp ;
use IO::Handle ;
use Scalar::Util qw(dualvar);

use IO::Compress::Base::Common 2.033 ;
use Compress::Raw::Zlib 2.033 ;
use IO::Compress::Gzip 2.033 ;
use IO::Uncompress::Gunzip 2.033 ;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = '2.033';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
        deflateInit inflateInit

        compress uncompress

        gzopen $gzerrno
    );

push @EXPORT, @Compress::Raw::Zlib::EXPORT ;

@EXPORT_OK = qw(memGunzip memGzip zlib_version);
%EXPORT_TAGS = (
    ALL         => \@EXPORT
);

BEGIN
{
    *zlib_version = \&Compress::Raw::Zlib::zlib_version;
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;

our (@my_z_errmsg);

@my_z_errmsg = (
    "need dictionary",     # Z_NEED_DICT     2
    "stream end",          # Z_STREAM_END    1
    "",                    # Z_OK            0
    "file error",          # Z_ERRNO        (-1)
    "stream error",        # Z_STREAM_ERROR (-2)
    "data error",          # Z_DATA_ERROR   (-3)
    "insufficient memory", # Z_MEM_ERROR    (-4)
    "buffer error",        # Z_BUF_ERROR    (-5)
    "incompatible version",# Z_VERSION_ERROR(-6)
    );


sub _set_gzerr
{
    my $value = shift ;

    if ($value == 0) {
        $Compress::Zlib::gzerrno = 0 ;
    }
    elsif ($value == Z_ERRNO() || $value > 2) {
        $Compress::Zlib::gzerrno = $! ;
    }
    else {
        $Compress::Zlib::gzerrno = dualvar($value+0, $my_z_errmsg[2 - $value]);
    }

    return $value ;
}

sub _set_gzerr_undef
{
    _set_gzerr(@_);
    return undef;
}
sub _save_gzerr
{
    my $gz = shift ;
    my $test_eof = shift ;

    my $value = $gz->errorNo() || 0 ;

    if ($test_eof) {
        #my $gz = $self->[0] ;
        # gzread uses Z_STREAM_END to denote a successful end
        $value = Z_STREAM_END() if $gz->eof() && $value == 0 ;
    }

    _set_gzerr($value) ;
}

sub gzopen($$)
{
    my ($file, $mode) = @_ ;

    my $gz ;
    my %defOpts = (Level    => Z_DEFAULT_COMPRESSION(),
                   Strategy => Z_DEFAULT_STRATEGY(),
                  );

    my $writing ;
    $writing = ! ($mode =~ /r/i) ;
    $writing = ($mode =~ /[wa]/i) ;

    $defOpts{Level}    = $1               if $mode =~ /(\d)/;
    $defOpts{Strategy} = Z_FILTERED()     if $mode =~ /f/i;
    $defOpts{Strategy} = Z_HUFFMAN_ONLY() if $mode =~ /h/i;
    $defOpts{Append}   = 1                if $mode =~ /a/i;

    my $infDef = $writing ? 'deflate' : 'inflate';
    my @params = () ;

    croak "gzopen: file parameter is not a filehandle or filename"
        unless isaFilehandle $file || isaFilename $file  || 
               (ref $file && ref $file eq 'SCALAR');

    return undef unless $mode =~ /[rwa]/i ;

    _set_gzerr(0) ;

    if ($writing) {
        $gz = new IO::Compress::Gzip($file, Minimal => 1, AutoClose => 1, 
                                     %defOpts) 
            or $Compress::Zlib::gzerrno = $IO::Compress::Gzip::GzipError;
    }
    else {
        $gz = new IO::Uncompress::Gunzip($file, 
                                         Transparent => 1,
                                         Append => 0, 
                                         AutoClose => 1, 
                                         MultiStream => 1,
                                         Strict => 0) 
            or $Compress::Zlib::gzerrno = $IO::Uncompress::Gunzip::GunzipError;
    }

    return undef
        if ! defined $gz ;

    bless [$gz, $infDef], 'Compress::Zlib::gzFile';
}

sub Compress::Zlib::gzFile::gzread
{
    my $self = shift ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'inflate';

    my $len = defined $_[1] ? $_[1] : 4096 ; 

    if ($self->gzeof() || $len == 0) {
        # Zap the output buffer to match ver 1 behaviour.
        $_[0] = "" ;
        return 0 ;
    }

    my $gz = $self->[0] ;
    my $status = $gz->read($_[0], $len) ; 
    _save_gzerr($gz, 1);
    return $status ;
}

sub Compress::Zlib::gzFile::gzreadline
{
    my $self = shift ;

    my $gz = $self->[0] ;
    {
        # Maintain backward compatibility with 1.x behaviour
        # It didn't support $/, so this can't either.
        local $/ = "\n" ;
        $_[0] = $gz->getline() ; 
    }
    _save_gzerr($gz, 1);
    return defined $_[0] ? length $_[0] : 0 ;
}

sub Compress::Zlib::gzFile::gzwrite
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';

    $] >= 5.008 and (utf8::downgrade($_[0], 1) 
        or croak "Wide character in gzwrite");

    my $status = $gz->write($_[0]) ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gztell
{
    my $self = shift ;
    my $gz = $self->[0] ;
    my $status = $gz->tell() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzseek
{
    my $self   = shift ;
    my $offset = shift ;
    my $whence = shift ;

    my $gz = $self->[0] ;
    my $status ;
    eval { $status = $gz->seek($offset, $whence) ; };
    if ($@)
    {
        my $error = $@;
        $error =~ s/^.*: /gzseek: /;
        $error =~ s/ at .* line \d+\s*$//;
        croak $error;
    }
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzflush
{
    my $self = shift ;
    my $f    = shift ;

    my $gz = $self->[0] ;
    my $status = $gz->flush($f) ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzclose
{
    my $self = shift ;
    my $gz = $self->[0] ;

    my $status = $gz->close() ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzeof
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return 0
        if $self->[1] ne 'inflate';

    my $status = $gz->eof() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzsetparams
{
    my $self = shift ;
    croak "Usage: Compress::Zlib::gzFile::gzsetparams(file, level, strategy)"
        unless @_ eq 2 ;

    my $gz = $self->[0] ;
    my $level = shift ;
    my $strategy = shift;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';
 
    my $status = *$gz->{Compress}->deflateParams(-Level   => $level, 
                                                -Strategy => $strategy);
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzerror
{
    my $self = shift ;
    my $gz = $self->[0] ;
    
    return $Compress::Zlib::gzerrno ;
}


sub compress($;$)
{
    my ($x, $output, $err, $in) =('', '', '', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in compress");

    my $level = (@_ == 2 ? $_[1] : Z_DEFAULT_COMPRESSION() );

    $x = new Compress::Raw::Zlib::Deflate -AppendOutput => 1, -Level => $level
            or return undef ;

    $err = $x->deflate($in, $output) ;
    return undef unless $err == Z_OK() ;

    $err = $x->flush($output) ;
    return undef unless $err == Z_OK() ;
    
    return $output ;

}

sub uncompress($)
{
    my ($x, $output, $err, $in) =('', '', '', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in uncompress");

    $x = new Compress::Raw::Zlib::Inflate -ConsumeInput => 0 or return undef ;
 
    $err = $x->inflate($in, $output) ;
    return undef unless $err == Z_STREAM_END() ;
 
    return $output ;
}


 
sub deflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
                }, @_ ) ;

    croak "Compress::Zlib::deflateInit: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $obj ;
 
    my $status = 0 ;
    ($obj, $status) = 
      Compress::Raw::Zlib::_deflateInit(0,
                $got->value('Level'), 
                $got->value('Method'), 
                $got->value('WindowBits'), 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                $got->value('Dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldDeflate"  : undef) ;
    return wantarray ? ($x, $status) : $x ;
}
 
sub inflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
                }, @_) ;


    croak "Compress::Zlib::inflateInit: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $status = 0 ;
    my $obj ;
    ($obj, $status) = Compress::Raw::Zlib::_inflateInit(FLAG_CONSUME_INPUT,
                                $got->value('WindowBits'), 
                                $got->value('Bufsize'), 
                                $got->value('Dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldInflate"  : undef) ;

    wantarray ? ($x, $status) : $x ;
}

package Zlib::OldDeflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::deflateStream);


sub deflate
{
    my $self = shift ;
    my $output ;

    my $status = $self->SUPER::deflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

sub flush
{
    my $self = shift ;
    my $output ;
    my $flag = shift || Compress::Zlib::Z_FINISH();
    my $status = $self->SUPER::flush($output, $flag) ;
    
    wantarray ? ($output, $status) : $output ;
}

package Zlib::OldInflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::inflateStream);

sub inflate
{
    my $self = shift ;
    my $output ;
    my $status = $self->SUPER::inflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

package Compress::Zlib ;

use IO::Compress::Gzip::Constants 2.033 ;

sub memGzip($)
{
  my $out;

  # if the deflation buffer isn't a reference, make it one
  my $string = (ref $_[0] ? $_[0] : \$_[0]) ;

  $] >= 5.008 and (utf8::downgrade($$string, 1) 
      or croak "Wide character in memGzip");

  _set_gzerr(0);
  if ( ! IO::Compress::Gzip::gzip($string, \$out, Minimal => 1) )
  {
      $Compress::Zlib::gzerrno = $IO::Compress::Gzip::GzipError;
      return undef ;
  }

  return $out;
}

sub _removeGzipHeader($)
{
    my $string = shift ;

    return Z_DATA_ERROR() 
        if length($$string) < GZIP_MIN_HEADER_SIZE ;

    my ($magic1, $magic2, $method, $flags, $time, $xflags, $oscode) = 
        unpack ('CCCCVCC', $$string);

    return Z_DATA_ERROR()
        unless $magic1 == GZIP_ID1 and $magic2 == GZIP_ID2 and
           $method == Z_DEFLATED() and !($flags & GZIP_FLG_RESERVED) ;
    substr($$string, 0, GZIP_MIN_HEADER_SIZE) = '' ;

    # skip extra field
    if ($flags & GZIP_FLG_FEXTRA)
    {
        return Z_DATA_ERROR()
            if length($$string) < GZIP_FEXTRA_HEADER_SIZE ;

        my ($extra_len) = unpack ('v', $$string);
        $extra_len += GZIP_FEXTRA_HEADER_SIZE;
        return Z_DATA_ERROR()
            if length($$string) < $extra_len ;

        substr($$string, 0, $extra_len) = '';
    }

    # skip orig name
    if ($flags & GZIP_FLG_FNAME)
    {
        my $name_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
           if $name_end == -1 ;
        substr($$string, 0, $name_end + 1) =  '';
    }

    # skip comment
    if ($flags & GZIP_FLG_FCOMMENT)
    {
        my $comment_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
            if $comment_end == -1 ;
        substr($$string, 0, $comment_end + 1) = '';
    }

    # skip header crc
    if ($flags & GZIP_FLG_FHCRC)
    {
        return Z_DATA_ERROR()
            if length ($$string) < GZIP_FHCRC_SIZE ;
        substr($$string, 0, GZIP_FHCRC_SIZE) = '';
    }
    
    return Z_OK();
}

sub _ret_gun_error
{
    $Compress::Zlib::gzerrno = $IO::Uncompress::Gunzip::GunzipError;
    return undef;
}


sub memGunzip($)
{
    # if the buffer isn't a reference, make it one
    my $string = (ref $_[0] ? $_[0] : \$_[0]);
 
    $] >= 5.008 and (utf8::downgrade($$string, 1) 
        or croak "Wide character in memGunzip");

    _set_gzerr(0);

    my $status = _removeGzipHeader($string) ;
    $status == Z_OK() 
        or return _set_gzerr_undef($status);
     
    my $bufsize = length $$string > 4096 ? length $$string : 4096 ;
    my $x = new Compress::Raw::Zlib::Inflate({-WindowBits => - MAX_WBITS(),
                         -Bufsize => $bufsize}) 

              or return _ret_gun_error();

    my $output = "" ;
    $status = $x->inflate($string, $output);
    
    if ( $status == Z_OK() )
    {
        _set_gzerr(Z_DATA_ERROR());
        return undef;
    }

    return _ret_gun_error()
        if ($status != Z_STREAM_END());

    if (length $$string >= 8)
    {
        my ($crc, $len) = unpack ("VV", substr($$string, 0, 8));
        substr($$string, 0, 8) = '';
        return _set_gzerr_undef(Z_DATA_ERROR())
            unless $len == length($output) and
                   $crc == crc32($output);
    }
    else
    {
        $$string = '';
    }

    return $output;   
}

# Autoload methods go after __END__, and are processed by the autosplit program.

1;
__END__


#line 1484
FILE   c2caccfd/Digest/base.pm  �#line 1 "/usr/share/perl/5.14/Digest/base.pm"
package Digest::base;

use strict;
use vars qw($VERSION);
$VERSION = "1.16";

# subclass is supposed to implement at least these
sub new;
sub clone;
sub add;
sub digest;

sub reset {
    my $self = shift;
    $self->new(@_);  # ugly
}

sub addfile {
    my ($self, $handle) = @_;

    my $n;
    my $buf = "";

    while (($n = read($handle, $buf, 4*1024))) {
        $self->add($buf);
    }
    unless (defined $n) {
	require Carp;
	Carp::croak("Read failed: $!");
    }

    $self;
}

sub add_bits {
    my $self = shift;
    my $bits;
    my $nbits;
    if (@_ == 1) {
	my $arg = shift;
	$bits = pack("B*", $arg);
	$nbits = length($arg);
    }
    else {
	($bits, $nbits) = @_;
    }
    if (($nbits % 8) != 0) {
	require Carp;
	Carp::croak("Number of bits must be multiple of 8 for this algorithm");
    }
    return $self->add(substr($bits, 0, $nbits/8));
}

sub hexdigest {
    my $self = shift;
    return unpack("H*", $self->digest(@_));
}

sub b64digest {
    my $self = shift;
    require MIME::Base64;
    my $b64 = MIME::Base64::encode($self->digest(@_), "");
    $b64 =~ s/=+$//;
    return $b64;
}

1;

__END__

#line 101FILE   d6e7fc74/Exporter.pm  	y#line 1 "/usr/share/perl/5.14/Exporter.pm"
package Exporter;

require 5.006;

# Be lean.
#use strict;
#no strict 'refs';

our $Debug = 0;
our $ExportLevel = 0;
our $Verbose ||= 0;
our $VERSION = '5.64_03';
our (%Cache);

sub as_heavy {
  require Exporter::Heavy;
  # Unfortunately, this does not work if the caller is aliased as *name = \&foo
  # Thus the need to create a lot of identical subroutines
  my $c = (caller(1))[3];
  $c =~ s/.*:://;
  \&{"Exporter::Heavy::heavy_$c"};
}

sub export {
  goto &{as_heavy()};
}

sub import {
  my $pkg = shift;
  my $callpkg = caller($ExportLevel);

  if ($pkg eq "Exporter" and @_ and $_[0] eq "import") {
    *{$callpkg."::import"} = \&import;
    return;
  }

  # We *need* to treat @{"$pkg\::EXPORT_FAIL"} since Carp uses it :-(
  my $exports = \@{"$pkg\::EXPORT"};
  # But, avoid creating things if they don't exist, which saves a couple of
  # hundred bytes per package processed.
  my $fail = ${$pkg . '::'}{EXPORT_FAIL} && \@{"$pkg\::EXPORT_FAIL"};
  return export $pkg, $callpkg, @_
    if $Verbose or $Debug or $fail && @$fail > 1;
  my $export_cache = ($Cache{$pkg} ||= {});
  my $args = @_ or @_ = @$exports;

  local $_;
  if ($args and not %$export_cache) {
    s/^&//, $export_cache->{$_} = 1
      foreach (@$exports, @{"$pkg\::EXPORT_OK"});
  }
  my $heavy;
  # Try very hard not to use {} and hence have to  enter scope on the foreach
  # We bomb out of the loop with last as soon as heavy is set.
  if ($args or $fail) {
    ($heavy = (/\W/ or $args and not exists $export_cache->{$_}
               or $fail and @$fail and $_ eq $fail->[0])) and last
                 foreach (@_);
  } else {
    ($heavy = /\W/) and last
      foreach (@_);
  }
  return export $pkg, $callpkg, ($args ? @_ : ()) if $heavy;
  local $SIG{__WARN__} = 
	sub {require Carp; &Carp::carp} if not $SIG{__WARN__};
  # shortcut for the common case of no type character
  *{"$callpkg\::$_"} = \&{"$pkg\::$_"} foreach @_;
}

# Default methods

sub export_fail {
    my $self = shift;
    @_;
}

# Unfortunately, caller(1)[3] "does not work" if the caller is aliased as
# *name = \&foo.  Thus the need to create a lot of identical subroutines
# Otherwise we could have aliased them to export().

sub export_to_level {
  goto &{as_heavy()};
}

sub export_tags {
  goto &{as_heavy()};
}

sub export_ok_tags {
  goto &{as_heavy()};
}

sub require_version {
  goto &{as_heavy()};
}

1;
__END__

FILE   a0faf844/Exporter/Heavy.pm  �#line 1 "/usr/share/perl/5.14/Exporter/Heavy.pm"
package Exporter::Heavy;

use strict;
no strict 'refs';

# On one line so MakeMaker will see it.
require Exporter;  our $VERSION = $Exporter::VERSION;

#
# We go to a lot of trouble not to 'require Carp' at file scope,
#  because Carp requires Exporter, and something has to give.
#

sub _rebuild_cache {
    my ($pkg, $exports, $cache) = @_;
    s/^&// foreach @$exports;
    @{$cache}{@$exports} = (1) x @$exports;
    my $ok = \@{"${pkg}::EXPORT_OK"};
    if (@$ok) {
	s/^&// foreach @$ok;
	@{$cache}{@$ok} = (1) x @$ok;
    }
}

sub heavy_export {

    # First make import warnings look like they're coming from the "use".
    local $SIG{__WARN__} = sub {
	my $text = shift;
	if ($text =~ s/ at \S*Exporter\S*.pm line \d+.*\n//) {
	    require Carp;
	    local $Carp::CarpLevel = 1;	# ignore package calling us too.
	    Carp::carp($text);
	}
	else {
	    warn $text;
	}
    };
    local $SIG{__DIE__} = sub {
	require Carp;
	local $Carp::CarpLevel = 1;	# ignore package calling us too.
	Carp::croak("$_[0]Illegal null symbol in \@${1}::EXPORT")
	    if $_[0] =~ /^Unable to create sub named "(.*?)::"/;
    };

    my($pkg, $callpkg, @imports) = @_;
    my($type, $sym, $cache_is_current, $oops);
    my($exports, $export_cache) = (\@{"${pkg}::EXPORT"},
                                   $Exporter::Cache{$pkg} ||= {});

    if (@imports) {
	if (!%$export_cache) {
	    _rebuild_cache ($pkg, $exports, $export_cache);
	    $cache_is_current = 1;
	}

	if (grep m{^[/!:]}, @imports) {
	    my $tagsref = \%{"${pkg}::EXPORT_TAGS"};
	    my $tagdata;
	    my %imports;
	    my($remove, $spec, @names, @allexports);
	    # negated first item implies starting with default set:
	    unshift @imports, ':DEFAULT' if $imports[0] =~ m/^!/;
	    foreach $spec (@imports){
		$remove = $spec =~ s/^!//;

		if ($spec =~ s/^://){
		    if ($spec eq 'DEFAULT'){
			@names = @$exports;
		    }
		    elsif ($tagdata = $tagsref->{$spec}) {
			@names = @$tagdata;
		    }
		    else {
			warn qq["$spec" is not defined in %${pkg}::EXPORT_TAGS];
			++$oops;
			next;
		    }
		}
		elsif ($spec =~ m:^/(.*)/$:){
		    my $patn = $1;
		    @allexports = keys %$export_cache unless @allexports; # only do keys once
		    @names = grep(/$patn/, @allexports); # not anchored by default
		}
		else {
		    @names = ($spec); # is a normal symbol name
		}

		warn "Import ".($remove ? "del":"add").": @names "
		    if $Exporter::Verbose;

		if ($remove) {
		   foreach $sym (@names) { delete $imports{$sym} } 
		}
		else {
		    @imports{@names} = (1) x @names;
		}
	    }
	    @imports = keys %imports;
	}

        my @carp;
	foreach $sym (@imports) {
	    if (!$export_cache->{$sym}) {
		if ($sym =~ m/^\d/) {
		    $pkg->VERSION($sym); # inherit from UNIVERSAL
		    # If the version number was the only thing specified
		    # then we should act as if nothing was specified:
		    if (@imports == 1) {
			@imports = @$exports;
			last;
		    }
		    # We need a way to emulate 'use Foo ()' but still
		    # allow an easy version check: "use Foo 1.23, ''";
		    if (@imports == 2 and !$imports[1]) {
			@imports = ();
			last;
		    }
		} elsif ($sym !~ s/^&// || !$export_cache->{$sym}) {
		    # Last chance - see if they've updated EXPORT_OK since we
		    # cached it.

		    unless ($cache_is_current) {
			%$export_cache = ();
			_rebuild_cache ($pkg, $exports, $export_cache);
			$cache_is_current = 1;
		    }

		    if (!$export_cache->{$sym}) {
			# accumulate the non-exports
			push @carp,
			  qq["$sym" is not exported by the $pkg module\n];
			$oops++;
		    }
		}
	    }
	}
	if ($oops) {
	    require Carp;
	    Carp::croak("@{carp}Can't continue after import errors");
	}
    }
    else {
	@imports = @$exports;
    }

    my($fail, $fail_cache) = (\@{"${pkg}::EXPORT_FAIL"},
                              $Exporter::FailCache{$pkg} ||= {});

    if (@$fail) {
	if (!%$fail_cache) {
	    # Build cache of symbols. Optimise the lookup by adding
	    # barewords twice... both with and without a leading &.
	    # (Technique could be applied to $export_cache at cost of memory)
	    my @expanded = map { /^\w/ ? ($_, '&'.$_) : $_ } @$fail;
	    warn "${pkg}::EXPORT_FAIL cached: @expanded" if $Exporter::Verbose;
	    @{$fail_cache}{@expanded} = (1) x @expanded;
	}
	my @failed;
	foreach $sym (@imports) { push(@failed, $sym) if $fail_cache->{$sym} }
	if (@failed) {
	    @failed = $pkg->export_fail(@failed);
	    foreach $sym (@failed) {
                require Carp;
		Carp::carp(qq["$sym" is not implemented by the $pkg module ],
			"on this architecture");
	    }
	    if (@failed) {
		require Carp;
		Carp::croak("Can't continue after import errors");
	    }
	}
    }

    warn "Importing into $callpkg from $pkg: ",
		join(", ",sort @imports) if $Exporter::Verbose;

    foreach $sym (@imports) {
	# shortcut for the common case of no type character
	(*{"${callpkg}::$sym"} = \&{"${pkg}::$sym"}, next)
	    unless $sym =~ s/^(\W)//;
	$type = $1;
	no warnings 'once';
	*{"${callpkg}::$sym"} =
	    $type eq '&' ? \&{"${pkg}::$sym"} :
	    $type eq '$' ? \${"${pkg}::$sym"} :
	    $type eq '@' ? \@{"${pkg}::$sym"} :
	    $type eq '%' ? \%{"${pkg}::$sym"} :
	    $type eq '*' ?  *{"${pkg}::$sym"} :
	    do { require Carp; Carp::croak("Can't export symbol: $type$sym") };
    }
}

sub heavy_export_to_level
{
      my $pkg = shift;
      my $level = shift;
      (undef) = shift;			# XXX redundant arg
      my $callpkg = caller($level);
      $pkg->export($callpkg, @_);
}

# Utility functions

sub _push_tags {
    my($pkg, $var, $syms) = @_;
    my @nontag = ();
    my $export_tags = \%{"${pkg}::EXPORT_TAGS"};
    push(@{"${pkg}::$var"},
	map { $export_tags->{$_} ? @{$export_tags->{$_}} 
                                 : scalar(push(@nontag,$_),$_) }
		(@$syms) ? @$syms : keys %$export_tags);
    if (@nontag and $^W) {
	# This may change to a die one day
	require Carp;
	Carp::carp(join(", ", @nontag)." are not tags of $pkg");
    }
}

sub heavy_require_version {
    my($self, $wanted) = @_;
    my $pkg = ref $self || $self;
    return ${pkg}->VERSION($wanted);
}

sub heavy_export_tags {
  _push_tags((caller)[0], "EXPORT",    \@_);
}

sub heavy_export_ok_tags {
  _push_tags((caller)[0], "EXPORT_OK", \@_);
}

1;
FILE   57828794/File/Basename.pm  �#line 1 "/usr/share/perl/5.14/File/Basename.pm"

#line 36


package File::Basename;

# File::Basename is used during the Perl build, when the re extension may
# not be available, but we only actually need it if running under tainting.
BEGIN {
  if (${^TAINT}) {
    require re;
    re->import('taint');
  }
}


use strict;
use 5.006;
use warnings;
our(@ISA, @EXPORT, $VERSION, $Fileparse_fstype, $Fileparse_igncase);
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(fileparse fileparse_set_fstype basename dirname);
$VERSION = "2.82";

fileparse_set_fstype($^O);


#line 102


sub fileparse {
  my($fullname,@suffices) = @_;

  unless (defined $fullname) {
      require Carp;
      Carp::croak("fileparse(): need a valid pathname");
  }

  my $orig_type = '';
  my($type,$igncase) = ($Fileparse_fstype, $Fileparse_igncase);

  my($taint) = substr($fullname,0,0);  # Is $fullname tainted?

  if ($type eq "VMS" and $fullname =~ m{/} ) {
    # We're doing Unix emulation
    $orig_type = $type;
    $type = 'Unix';
  }

  my($dirpath, $basename);

  if (grep { $type eq $_ } qw(MSDOS DOS MSWin32 Epoc)) {
    ($dirpath,$basename) = ($fullname =~ /^((?:.*[:\\\/])?)(.*)/s);
    $dirpath .= '.\\' unless $dirpath =~ /[\\\/]\z/;
  }
  elsif ($type eq "OS2") {
    ($dirpath,$basename) = ($fullname =~ m#^((?:.*[:\\/])?)(.*)#s);
    $dirpath = './' unless $dirpath;	# Can't be 0
    $dirpath .= '/' unless $dirpath =~ m#[\\/]\z#;
  }
  elsif ($type eq "MacOS") {
    ($dirpath,$basename) = ($fullname =~ /^(.*:)?(.*)/s);
    $dirpath = ':' unless $dirpath;
  }
  elsif ($type eq "AmigaOS") {
    ($dirpath,$basename) = ($fullname =~ /(.*[:\/])?(.*)/s);
    $dirpath = './' unless $dirpath;
  }
  elsif ($type eq 'VMS' ) {
    ($dirpath,$basename) = ($fullname =~ /^(.*[:>\]])?(.*)/s);
    $dirpath ||= '';  # should always be defined
  }
  else { # Default to Unix semantics.
    ($dirpath,$basename) = ($fullname =~ m{^(.*/)?(.*)}s);
    if ($orig_type eq 'VMS' and $fullname =~ m{^(/[^/]+/000000(/|$))(.*)}) {
      # dev:[000000] is top of VMS tree, similar to Unix '/'
      # so strip it off and treat the rest as "normal"
      my $devspec  = $1;
      my $remainder = $3;
      ($dirpath,$basename) = ($remainder =~ m{^(.*/)?(.*)}s);
      $dirpath ||= '';  # should always be defined
      $dirpath = $devspec.$dirpath;
    }
    $dirpath = './' unless $dirpath;
  }
      

  my $tail   = '';
  my $suffix = '';
  if (@suffices) {
    foreach $suffix (@suffices) {
      my $pat = ($igncase ? '(?i)' : '') . "($suffix)\$";
      if ($basename =~ s/$pat//s) {
        $taint .= substr($suffix,0,0);
        $tail = $1 . $tail;
      }
    }
  }

  # Ensure taint is propagated from the path to its pieces.
  $tail .= $taint;
  wantarray ? ($basename .= $taint, $dirpath .= $taint, $tail)
            : ($basename .= $taint);
}



#line 212


sub basename {
  my($path) = shift;

  # From BSD basename(1)
  # The basename utility deletes any prefix ending with the last slash `/'
  # character present in string (after first stripping trailing slashes)
  _strip_trailing_sep($path);

  my($basename, $dirname, $suffix) = fileparse( $path, map("\Q$_\E",@_) );

  # From BSD basename(1)
  # The suffix is not stripped if it is identical to the remaining 
  # characters in string.
  if( length $suffix and !length $basename ) {
      $basename = $suffix;
  }
  
  # Ensure that basename '/' == '/'
  if( !length $basename ) {
      $basename = $dirname;
  }

  return $basename;
}



#line 281


sub dirname {
    my $path = shift;

    my($type) = $Fileparse_fstype;

    if( $type eq 'VMS' and $path =~ m{/} ) {
        # Parse as Unix
        local($File::Basename::Fileparse_fstype) = '';
        return dirname($path);
    }

    my($basename, $dirname) = fileparse($path);

    if ($type eq 'VMS') { 
        $dirname ||= $ENV{DEFAULT};
    }
    elsif ($type eq 'MacOS') {
	if( !length($basename) && $dirname !~ /^[^:]+:\z/) {
            _strip_trailing_sep($dirname);
	    ($basename,$dirname) = fileparse $dirname;
	}
	$dirname .= ":" unless $dirname =~ /:\z/;
    }
    elsif (grep { $type eq $_ } qw(MSDOS DOS MSWin32 OS2)) { 
        _strip_trailing_sep($dirname);
        unless( length($basename) ) {
	    ($basename,$dirname) = fileparse $dirname;
	    _strip_trailing_sep($dirname);
	}
    }
    elsif ($type eq 'AmigaOS') {
        if ( $dirname =~ /:\z/) { return $dirname }
        chop $dirname;
        $dirname =~ s{[^:/]+\z}{} unless length($basename);
    }
    else {
        _strip_trailing_sep($dirname);
        unless( length($basename) ) {
	    ($basename,$dirname) = fileparse $dirname;
	    _strip_trailing_sep($dirname);
	}
    }

    $dirname;
}


# Strip the trailing path separator.
sub _strip_trailing_sep  {
    my $type = $Fileparse_fstype;

    if ($type eq 'MacOS') {
        $_[0] =~ s/([^:]):\z/$1/s;
    }
    elsif (grep { $type eq $_ } qw(MSDOS DOS MSWin32 OS2)) { 
        $_[0] =~ s/([^:])[\\\/]*\z/$1/;
    }
    else {
        $_[0] =~ s{(.)/*\z}{$1}s;
    }
}


#line 369


BEGIN {

my @Ignore_Case = qw(MacOS VMS AmigaOS OS2 RISCOS MSWin32 MSDOS DOS Epoc);
my @Types = (@Ignore_Case, qw(Unix));

sub fileparse_set_fstype {
    my $old = $Fileparse_fstype;

    if (@_) {
        my $new_type = shift;

        $Fileparse_fstype = 'Unix';  # default
        foreach my $type (@Types) {
            $Fileparse_fstype = $type if $new_type =~ /^$type/i;
        }

        $Fileparse_igncase = 
          (grep $Fileparse_fstype eq $_, @Ignore_Case) ? 1 : 0;
    }

    return $old;
}

}


1;


#line 403FILE   067a38ed/File/Copy.pm  /�#line 1 "/usr/share/perl/5.14/File/Copy.pm"
# File/Copy.pm. Written in 1994 by Aaron Sherman <ajs@ajs.com>. This
# source code has been placed in the public domain by the author.
# Please be kind and preserve the documentation.
#
# Additions copyright 1996 by Charles Bailey.  Permission is granted
# to distribute the revised code under the same terms as Perl itself.

package File::Copy;

use 5.006;
use strict;
use warnings;
use File::Spec;
use Config;
# During perl build, we need File::Copy but Scalar::Util might not be built yet
# And then we need these games to avoid loading overload, as that will
# confuse miniperl during the bootstrap of perl.
my $Scalar_Util_loaded = eval q{ require Scalar::Util; require overload; 1 };
our(@ISA, @EXPORT, @EXPORT_OK, $VERSION, $Too_Big, $Syscopy_is_copy);
sub copy;
sub syscopy;
sub cp;
sub mv;

$VERSION = '2.21';

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(copy move);
@EXPORT_OK = qw(cp mv);

$Too_Big = 1024 * 1024 * 2;

sub croak {
    require Carp;
    goto &Carp::croak;
}

sub carp {
    require Carp;
    goto &Carp::carp;
}

# Look up the feature settings on VMS using VMS::Feature when available.

my $use_vms_feature = 0;
BEGIN {
    if ($^O eq 'VMS') {
        if (eval { local $SIG{__DIE__}; require VMS::Feature; }) {
            $use_vms_feature = 1;
        }
    }
}

# Need to look up the UNIX report mode.  This may become a dynamic mode
# in the future.
sub _vms_unix_rpt {
    my $unix_rpt;
    if ($use_vms_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    } else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i;
    }
    return $unix_rpt;
}

# Need to look up the EFS character set mode.  This may become a dynamic
# mode in the future.
sub _vms_efs {
    my $efs;
    if ($use_vms_feature) {
        $efs = VMS::Feature::current("efs_charset");
    } else {
        my $env_efs = $ENV{'DECC$EFS_CHARSET'} || '';
        $efs = $env_efs =~ /^[ET1]/i;
    }
    return $efs;
}


sub _catname {
    my($from, $to) = @_;
    if (not defined &basename) {
	require File::Basename;
	import  File::Basename 'basename';
    }

    return File::Spec->catfile($to, basename($from));
}

# _eq($from, $to) tells whether $from and $to are identical
sub _eq {
    my ($from, $to) = map {
        $Scalar_Util_loaded && Scalar::Util::blessed($_)
	    && overload::Method($_, q{""})
            ? "$_"
            : $_
    } (@_);
    return '' if ( (ref $from) xor (ref $to) );
    return $from == $to if ref $from;
    return $from eq $to;
}

sub copy {
    croak("Usage: copy(FROM, TO [, BUFFERSIZE]) ")
      unless(@_ == 2 || @_ == 3);

    my $from = shift;
    my $to = shift;

    my $size;
    if (@_) {
	$size = shift(@_) + 0;
	croak("Bad buffer size for copy: $size\n") unless ($size > 0);
    }

    my $from_a_handle = (ref($from)
			 ? (ref($from) eq 'GLOB'
			    || UNIVERSAL::isa($from, 'GLOB')
                            || UNIVERSAL::isa($from, 'IO::Handle'))
			 : (ref(\$from) eq 'GLOB'));
    my $to_a_handle =   (ref($to)
			 ? (ref($to) eq 'GLOB'
			    || UNIVERSAL::isa($to, 'GLOB')
                            || UNIVERSAL::isa($to, 'IO::Handle'))
			 : (ref(\$to) eq 'GLOB'));

    if (_eq($from, $to)) { # works for references, too
	carp("'$from' and '$to' are identical (not copied)");
        # The "copy" was a success as the source and destination contain
        # the same data.
        return 1;
    }

    if ((($Config{d_symlink} && $Config{d_readlink}) || $Config{d_link}) &&
	!($^O eq 'MSWin32' || $^O eq 'os2')) {
	my @fs = stat($from);
	if (@fs) {
	    my @ts = stat($to);
	    if (@ts && $fs[0] == $ts[0] && $fs[1] == $ts[1] && !-p $from) {
		carp("'$from' and '$to' are identical (not copied)");
                return 0;
	    }
	}
    }

    if (!$from_a_handle && !$to_a_handle && -d $to && ! -d $from) {
	$to = _catname($from, $to);
    }

    if (defined &syscopy && !$Syscopy_is_copy
	&& !$to_a_handle
	&& !($from_a_handle && $^O eq 'os2' )	# OS/2 cannot handle handles
	&& !($from_a_handle && $^O eq 'mpeix')	# and neither can MPE/iX.
	&& !($from_a_handle && $^O eq 'MSWin32')
	&& !($from_a_handle && $^O eq 'NetWare')
       )
    {
	my $copy_to = $to;

        if ($^O eq 'VMS' && -e $from) {

            if (! -d $to && ! -d $from) {

                my $vms_efs = _vms_efs();
                my $unix_rpt = _vms_unix_rpt();
                my $unix_mode = 0;
                my $from_unix = 0;
                $from_unix = 1 if ($from =~ /^\.\.?$/);
                my $from_vms = 0;
                $from_vms = 1 if ($from =~ m#[\[<\]]#);

                # Need to know if we are in Unix mode.
                if ($from_vms == $from_unix) {
                    $unix_mode = $unix_rpt;
                } else {
                    $unix_mode = $from_unix;
                }

                # VMS has sticky defaults on extensions, which means that
                # if there is a null extension on the destination file, it
                # will inherit the extension of the source file
                # So add a '.' for a null extension.

                # In unix_rpt mode, the trailing dot should not be added.

                if ($vms_efs) {
                    $copy_to = $to;
                } else {
                    $copy_to = VMS::Filespec::vmsify($to);
                }
                my ($vol, $dirs, $file) = File::Spec->splitpath($copy_to);
                $file = $file . '.'
                    unless (($file =~ /(?<!\^)\./) || $unix_rpt);
                $copy_to = File::Spec->catpath($vol, $dirs, $file);

                # Get rid of the old versions to be like UNIX
                1 while unlink $copy_to;
            }
        }

        return syscopy($from, $copy_to) || 0;
    }

    my $closefrom = 0;
    my $closeto = 0;
    my ($status, $r, $buf);
    local($\) = '';

    my $from_h;
    if ($from_a_handle) {
       $from_h = $from;
    } else {
       open $from_h, "<", $from or goto fail_open1;
       binmode $from_h or die "($!,$^E)";
       $closefrom = 1;
    }

    # Seems most logical to do this here, in case future changes would want to
    # make this croak for some reason.
    unless (defined $size) {
	$size = tied(*$from_h) ? 0 : -s $from_h || 0;
	$size = 1024 if ($size < 512);
	$size = $Too_Big if ($size > $Too_Big);
    }

    my $to_h;
    if ($to_a_handle) {
       $to_h = $to;
    } else {
	$to_h = \do { local *FH }; # XXX is this line obsolete?
	open $to_h, ">", $to or goto fail_open2;
	binmode $to_h or die "($!,$^E)";
	$closeto = 1;
    }

    $! = 0;
    for (;;) {
	my ($r, $w, $t);
       defined($r = sysread($from_h, $buf, $size))
	    or goto fail_inner;
	last unless $r;
	for ($w = 0; $w < $r; $w += $t) {
           $t = syswrite($to_h, $buf, $r - $w, $w)
		or goto fail_inner;
	}
    }

    close($to_h) || goto fail_open2 if $closeto;
    close($from_h) || goto fail_open1 if $closefrom;

    # Use this idiom to avoid uninitialized value warning.
    return 1;

    # All of these contortions try to preserve error messages...
  fail_inner:
    if ($closeto) {
	$status = $!;
	$! = 0;
       close $to_h;
	$! = $status unless $!;
    }
  fail_open2:
    if ($closefrom) {
	$status = $!;
	$! = 0;
       close $from_h;
	$! = $status unless $!;
    }
  fail_open1:
    return 0;
}

sub cp {
    my($from,$to) = @_;
    my(@fromstat) = stat $from;
    my(@tostat) = stat $to;
    my $perm;

    return 0 unless copy(@_) and @fromstat;

    if (@tostat) {
        $perm = $tostat[2];
    } else {
        $perm = $fromstat[2] & ~(umask || 0);
	@tostat = stat $to;
    }
    # Might be more robust to look for S_I* in Fcntl, but we're
    # trying to avoid dependence on any XS-containing modules,
    # since File::Copy is used during the Perl build.
    $perm &= 07777;
    if ($perm & 06000) {
	croak("Unable to check setuid/setgid permissions for $to: $!")
	    unless @tostat;

	if ($perm & 04000 and                     # setuid
	    $fromstat[4] != $tostat[4]) {         # owner must match
	    $perm &= ~06000;
	}

	if ($perm & 02000 && $> != 0) {           # if not root, setgid
	    my $ok = $fromstat[5] == $tostat[5];  # group must match
	    if ($ok) {                            # and we must be in group
                $ok = grep { $_ == $fromstat[5] } split /\s+/, $)
	    }
	    $perm &= ~06000 unless $ok;
	}
    }
    return 0 unless @tostat;
    return 1 if $perm == ($tostat[2] & 07777);
    return eval { chmod $perm, $to; } ? 1 : 0;
}

sub _move {
    croak("Usage: move(FROM, TO) ") unless @_ == 3;

    my($from,$to,$fallback) = @_;

    my($fromsz,$tosz1,$tomt1,$tosz2,$tomt2,$sts,$ossts);

    if (-d $to && ! -d $from) {
	$to = _catname($from, $to);
    }

    ($tosz1,$tomt1) = (stat($to))[7,9];
    $fromsz = -s $from;
    if ($^O eq 'os2' and defined $tosz1 and defined $fromsz) {
      # will not rename with overwrite
      unlink $to;
    }

    my $rename_to = $to;
    if (-$^O eq 'VMS' && -e $from) {

        if (! -d $to && ! -d $from) {

            my $vms_efs = _vms_efs();
            my $unix_rpt = _vms_unix_rpt();
            my $unix_mode = 0;
            my $from_unix = 0;
            $from_unix = 1 if ($from =~ /^\.\.?$/);
            my $from_vms = 0;
            $from_vms = 1 if ($from =~ m#[\[<\]]#);

            # Need to know if we are in Unix mode.
            if ($from_vms == $from_unix) {
                $unix_mode = $unix_rpt;
            } else {
                $unix_mode = $from_unix;
            }

            # VMS has sticky defaults on extensions, which means that
            # if there is a null extension on the destination file, it
            # will inherit the extension of the source file
            # So add a '.' for a null extension.

            # In unix_rpt mode, the trailing dot should not be added.

            if ($vms_efs) {
                $rename_to = $to;
            } else {
                $rename_to = VMS::Filespec::vmsify($to);
            }
            my ($vol, $dirs, $file) = File::Spec->splitpath($rename_to);
            $file = $file . '.'
                unless (($file =~ /(?<!\^)\./) || $unix_rpt);
            $rename_to = File::Spec->catpath($vol, $dirs, $file);

            # Get rid of the old versions to be like UNIX
            1 while unlink $rename_to;
        }
    }

    return 1 if rename $from, $rename_to;

    # Did rename return an error even though it succeeded, because $to
    # is on a remote NFS file system, and NFS lost the server's ack?
    return 1 if defined($fromsz) && !-e $from &&           # $from disappeared
                (($tosz2,$tomt2) = (stat($to))[7,9]) &&    # $to's there
                  ((!defined $tosz1) ||			   #  not before or
		   ($tosz1 != $tosz2 or $tomt1 != $tomt2)) &&  #   was changed
                $tosz2 == $fromsz;                         # it's all there

    ($tosz1,$tomt1) = (stat($to))[7,9];  # just in case rename did something

    {
        local $@;
        eval {
            local $SIG{__DIE__};
            $fallback->($from,$to) or die;
            my($atime, $mtime) = (stat($from))[8,9];
            utime($atime, $mtime, $to);
            unlink($from)   or die;
        };
        return 1 unless $@;
    }
    ($sts,$ossts) = ($! + 0, $^E + 0);

    ($tosz2,$tomt2) = ((stat($to))[7,9],0,0) if defined $tomt1;
    unlink($to) if !defined($tomt1) or $tomt1 != $tomt2 or $tosz1 != $tosz2;
    ($!,$^E) = ($sts,$ossts);
    return 0;
}

sub move { _move(@_,\&copy); }
sub mv   { _move(@_,\&cp);   }

# &syscopy is an XSUB under OS/2
unless (defined &syscopy) {
    if ($^O eq 'VMS') {
	*syscopy = \&rmscopy;
    } elsif ($^O eq 'mpeix') {
	*syscopy = sub {
	    return 0 unless @_ == 2;
	    # Use the MPE cp program in order to
	    # preserve MPE file attributes.
	    return system('/bin/cp', '-f', $_[0], $_[1]) == 0;
	};
    } elsif ($^O eq 'MSWin32' && defined &DynaLoader::boot_DynaLoader) {
	# Win32::CopyFile() fill only work if we can load Win32.xs
	*syscopy = sub {
	    return 0 unless @_ == 2;
	    return Win32::CopyFile(@_, 1);
	};
    } else {
	$Syscopy_is_copy = 1;
	*syscopy = \&copy;
    }
}

1;

__END__

#line 596

FILE   fed3b8b3/File/Find.pm  T�#line 1 "/usr/share/perl/5.14/File/Find.pm"
package File::Find;
use 5.006;
use strict;
use warnings;
use warnings::register;
our $VERSION = '1.19';
require Exporter;
require Cwd;

#
# Modified to ensure sub-directory traversal order is not inverted by stack
# push and pops.  That is remains in the same order as in the directory file,
# or user pre-processing (EG:sorted).
#

#line 344

our @ISA = qw(Exporter);
our @EXPORT = qw(find finddepth);


use strict;
my $Is_VMS;
my $Is_Win32;

require File::Basename;
require File::Spec;

# Should ideally be my() not our() but local() currently
# refuses to operate on lexicals

our %SLnkSeen;
our ($wanted_callback, $avoid_nlink, $bydepth, $no_chdir, $follow,
    $follow_skip, $full_check, $untaint, $untaint_skip, $untaint_pat,
    $pre_process, $post_process, $dangling_symlinks);

sub contract_name {
    my ($cdir,$fn) = @_;

    return substr($cdir,0,rindex($cdir,'/')) if $fn eq $File::Find::current_dir;

    $cdir = substr($cdir,0,rindex($cdir,'/')+1);

    $fn =~ s|^\./||;

    my $abs_name= $cdir . $fn;

    if (substr($fn,0,3) eq '../') {
       1 while $abs_name =~ s!/[^/]*/\.\./+!/!;
    }

    return $abs_name;
}

sub PathCombine($$) {
    my ($Base,$Name) = @_;
    my $AbsName;

    if (substr($Name,0,1) eq '/') {
	$AbsName= $Name;
    }
    else {
	$AbsName= contract_name($Base,$Name);
    }

    # (simple) check for recursion
    my $newlen= length($AbsName);
    if ($newlen <= length($Base)) {
	if (($newlen == length($Base) || substr($Base,$newlen,1) eq '/')
	    && $AbsName eq substr($Base,0,$newlen))
	{
	    return undef;
	}
    }
    return $AbsName;
}

sub Follow_SymLink($) {
    my ($AbsName) = @_;

    my ($NewName,$DEV, $INO);
    ($DEV, $INO)= lstat $AbsName;

    while (-l _) {
	if ($SLnkSeen{$DEV, $INO}++) {
	    if ($follow_skip < 2) {
		die "$AbsName is encountered a second time";
	    }
	    else {
		return undef;
	    }
	}
	$NewName= PathCombine($AbsName, readlink($AbsName));
	unless(defined $NewName) {
	    if ($follow_skip < 2) {
		die "$AbsName is a recursive symbolic link";
	    }
	    else {
		return undef;
	    }
	}
	else {
	    $AbsName= $NewName;
	}
	($DEV, $INO) = lstat($AbsName);
	return undef unless defined $DEV;  #  dangling symbolic link
    }

    if ($full_check && defined $DEV && $SLnkSeen{$DEV, $INO}++) {
	if ( ($follow_skip < 1) || ((-d _) && ($follow_skip < 2)) ) {
	    die "$AbsName encountered a second time";
	}
	else {
	    return undef;
	}
    }

    return $AbsName;
}

our($dir, $name, $fullname, $prune);
sub _find_dir_symlnk($$$);
sub _find_dir($$$);

# check whether or not a scalar variable is tainted
# (code straight from the Camel, 3rd ed., page 561)
sub is_tainted_pp {
    my $arg = shift;
    my $nada = substr($arg, 0, 0); # zero-length
    local $@;
    eval { eval "# $nada" };
    return length($@) != 0;
}

sub _find_opt {
    my $wanted = shift;
    die "invalid top directory" unless defined $_[0];

    # This function must local()ize everything because callbacks may
    # call find() or finddepth()

    local %SLnkSeen;
    local ($wanted_callback, $avoid_nlink, $bydepth, $no_chdir, $follow,
	$follow_skip, $full_check, $untaint, $untaint_skip, $untaint_pat,
	$pre_process, $post_process, $dangling_symlinks);
    local($dir, $name, $fullname, $prune);
    local *_ = \my $a;

    my $cwd            = $wanted->{bydepth} ? Cwd::fastcwd() : Cwd::getcwd();
    if ($Is_VMS) {
	# VMS returns this by default in VMS format which just doesn't
	# work for the rest of this module.
	$cwd = VMS::Filespec::unixpath($cwd);

	# Apparently this is not expected to have a trailing space.
	# To attempt to make VMS/UNIX conversions mostly reversable,
	# a trailing slash is needed.  The run-time functions ignore the
	# resulting double slash, but it causes the perl tests to fail.
        $cwd =~ s#/\z##;

	# This comes up in upper case now, but should be lower.
	# In the future this could be exact case, no need to change.
    }
    my $cwd_untainted  = $cwd;
    my $check_t_cwd    = 1;
    $wanted_callback   = $wanted->{wanted};
    $bydepth           = $wanted->{bydepth};
    $pre_process       = $wanted->{preprocess};
    $post_process      = $wanted->{postprocess};
    $no_chdir          = $wanted->{no_chdir};
    $full_check        = $Is_Win32 ? 0 : $wanted->{follow};
    $follow            = $Is_Win32 ? 0 :
                             $full_check || $wanted->{follow_fast};
    $follow_skip       = $wanted->{follow_skip};
    $untaint           = $wanted->{untaint};
    $untaint_pat       = $wanted->{untaint_pattern};
    $untaint_skip      = $wanted->{untaint_skip};
    $dangling_symlinks = $wanted->{dangling_symlinks};

    # for compatibility reasons (find.pl, find2perl)
    local our ($topdir, $topdev, $topino, $topmode, $topnlink);

    # a symbolic link to a directory doesn't increase the link count
    $avoid_nlink      = $follow || $File::Find::dont_use_nlink;

    my ($abs_dir, $Is_Dir);

    Proc_Top_Item:
    foreach my $TOP (@_) {
	my $top_item = $TOP;

	($topdev,$topino,$topmode,$topnlink) = $follow ? stat $top_item : lstat $top_item;

	if ($Is_Win32) {
	    $top_item =~ s|[/\\]\z||
	      unless $top_item =~ m{^(?:\w:)?[/\\]$};
	}
	else {
	    $top_item =~ s|/\z|| unless $top_item eq '/';
	}

	$Is_Dir= 0;

	if ($follow) {

	    if (substr($top_item,0,1) eq '/') {
		$abs_dir = $top_item;
	    }
	    elsif ($top_item eq $File::Find::current_dir) {
		$abs_dir = $cwd;
	    }
	    else {  # care about any  ../
		$top_item =~ s/\.dir\z//i if $Is_VMS;
		$abs_dir = contract_name("$cwd/",$top_item);
	    }
	    $abs_dir= Follow_SymLink($abs_dir);
	    unless (defined $abs_dir) {
		if ($dangling_symlinks) {
		    if (ref $dangling_symlinks eq 'CODE') {
			$dangling_symlinks->($top_item, $cwd);
		    } else {
			warnings::warnif "$top_item is a dangling symbolic link\n";
		    }
		}
		next Proc_Top_Item;
	    }

	    if (-d _) {
		$top_item =~ s/\.dir\z//i if $Is_VMS;
		_find_dir_symlnk($wanted, $abs_dir, $top_item);
		$Is_Dir= 1;
	    }
	}
	else { # no follow
	    $topdir = $top_item;
	    unless (defined $topnlink) {
		warnings::warnif "Can't stat $top_item: $!\n";
		next Proc_Top_Item;
	    }
	    if (-d _) {
		$top_item =~ s/\.dir\z//i if $Is_VMS;
		_find_dir($wanted, $top_item, $topnlink);
		$Is_Dir= 1;
	    }
	    else {
		$abs_dir= $top_item;
	    }
	}

	unless ($Is_Dir) {
	    unless (($_,$dir) = File::Basename::fileparse($abs_dir)) {
		($dir,$_) = ('./', $top_item);
	    }

	    $abs_dir = $dir;
	    if (( $untaint ) && (is_tainted($dir) )) {
		( $abs_dir ) = $dir =~ m|$untaint_pat|;
		unless (defined $abs_dir) {
		    if ($untaint_skip == 0) {
			die "directory $dir is still tainted";
		    }
		    else {
			next Proc_Top_Item;
		    }
		}
	    }

	    unless ($no_chdir || chdir $abs_dir) {
		warnings::warnif "Couldn't chdir $abs_dir: $!\n";
		next Proc_Top_Item;
	    }

	    $name = $abs_dir . $_; # $File::Find::name
	    $_ = $name if $no_chdir;

	    { $wanted_callback->() }; # protect against wild "next"

	}

	unless ( $no_chdir ) {
	    if ( ($check_t_cwd) && (($untaint) && (is_tainted($cwd) )) ) {
		( $cwd_untainted ) = $cwd =~ m|$untaint_pat|;
		unless (defined $cwd_untainted) {
		    die "insecure cwd in find(depth)";
		}
		$check_t_cwd = 0;
	    }
	    unless (chdir $cwd_untainted) {
		die "Can't cd to $cwd: $!\n";
	    }
	}
    }
}

# API:
#  $wanted
#  $p_dir :  "parent directory"
#  $nlink :  what came back from the stat
# preconditions:
#  chdir (if not no_chdir) to dir

sub _find_dir($$$) {
    my ($wanted, $p_dir, $nlink) = @_;
    my ($CdLvl,$Level) = (0,0);
    my @Stack;
    my @filenames;
    my ($subcount,$sub_nlink);
    my $SE= [];
    my $dir_name= $p_dir;
    my $dir_pref;
    my $dir_rel = $File::Find::current_dir;
    my $tainted = 0;
    my $no_nlink;

    if ($Is_Win32) {
	$dir_pref
	  = ($p_dir =~ m{^(?:\w:[/\\]?|[/\\])$} ? $p_dir : "$p_dir/" );
    } elsif ($Is_VMS) {

	#	VMS is returning trailing .dir on directories
	#	and trailing . on files and symbolic links
	#	in UNIX syntax.
	#

	$p_dir =~ s/\.(dir)?$//i unless $p_dir eq '.';

	$dir_pref = ($p_dir =~ m/[\]>]+$/ ? $p_dir : "$p_dir/" );
    }
    else {
	$dir_pref= ( $p_dir eq '/' ? '/' : "$p_dir/" );
    }

    local ($dir, $name, $prune, *DIR);

    unless ( $no_chdir || ($p_dir eq $File::Find::current_dir)) {
	my $udir = $p_dir;
	if (( $untaint ) && (is_tainted($p_dir) )) {
	    ( $udir ) = $p_dir =~ m|$untaint_pat|;
	    unless (defined $udir) {
		if ($untaint_skip == 0) {
		    die "directory $p_dir is still tainted";
		}
		else {
		    return;
		}
	    }
	}
	unless (chdir ($Is_VMS && $udir !~ /[\/\[<]+/ ? "./$udir" : $udir)) {
	    warnings::warnif "Can't cd to $udir: $!\n";
	    return;
	}
    }

    # push the starting directory
    push @Stack,[$CdLvl,$p_dir,$dir_rel,-1]  if  $bydepth;

    while (defined $SE) {
	unless ($bydepth) {
	    $dir= $p_dir; # $File::Find::dir
	    $name= $dir_name; # $File::Find::name
	    $_= ($no_chdir ? $dir_name : $dir_rel ); # $_
	    # prune may happen here
	    $prune= 0;
	    { $wanted_callback->() };	# protect against wild "next"
	    next if $prune;
	}

	# change to that directory
	unless ($no_chdir || ($dir_rel eq $File::Find::current_dir)) {
	    my $udir= $dir_rel;
	    if ( ($untaint) && (($tainted) || ($tainted = is_tainted($dir_rel) )) ) {
		( $udir ) = $dir_rel =~ m|$untaint_pat|;
		unless (defined $udir) {
		    if ($untaint_skip == 0) {
			die "directory (" . ($p_dir ne '/' ? $p_dir : '') . "/) $dir_rel is still tainted";
		    } else { # $untaint_skip == 1
			next;
		    }
		}
	    }
	    unless (chdir ($Is_VMS && $udir !~ /[\/\[<]+/ ? "./$udir" : $udir)) {
		warnings::warnif "Can't cd to (" .
		    ($p_dir ne '/' ? $p_dir : '') . "/) $udir: $!\n";
		next;
	    }
	    $CdLvl++;
	}

	$dir= $dir_name; # $File::Find::dir

	# Get the list of files in the current directory.
	unless (opendir DIR, ($no_chdir ? $dir_name : $File::Find::current_dir)) {
	    warnings::warnif "Can't opendir($dir_name): $!\n";
	    next;
	}
	@filenames = readdir DIR;
	closedir(DIR);
	@filenames = $pre_process->(@filenames) if $pre_process;
	push @Stack,[$CdLvl,$dir_name,"",-2]   if $post_process;

	# default: use whatever was specified
        # (if $nlink >= 2, and $avoid_nlink == 0, this will switch back)
        $no_nlink = $avoid_nlink;
        # if dir has wrong nlink count, force switch to slower stat method
        $no_nlink = 1 if ($nlink < 2);

	if ($nlink == 2 && !$no_nlink) {
	    # This dir has no subdirectories.
	    for my $FN (@filenames) {
		if ($Is_VMS) {
		# Big hammer here - Compensate for VMS trailing . and .dir
		# No win situation until this is changed, but this
		# will handle the majority of the cases with breaking the fewest

		    $FN =~ s/\.dir\z//i;
		    $FN =~ s#\.$## if ($FN ne '.');
		}
		next if $FN =~ $File::Find::skip_pattern;
		
		$name = $dir_pref . $FN; # $File::Find::name
		$_ = ($no_chdir ? $name : $FN); # $_
		{ $wanted_callback->() }; # protect against wild "next"
	    }

	}
	else {
	    # This dir has subdirectories.
	    $subcount = $nlink - 2;

	    # HACK: insert directories at this position. so as to preserve
	    # the user pre-processed ordering of files.
	    # EG: directory traversal is in user sorted order, not at random.
            my $stack_top = @Stack;

	    for my $FN (@filenames) {
		next if $FN =~ $File::Find::skip_pattern;
		if ($subcount > 0 || $no_nlink) {
		    # Seen all the subdirs?
		    # check for directoriness.
		    # stat is faster for a file in the current directory
		    $sub_nlink = (lstat ($no_chdir ? $dir_pref . $FN : $FN))[3];

		    if (-d _) {
			--$subcount;
			$FN =~ s/\.dir\z//i if $Is_VMS;
			# HACK: replace push to preserve dir traversal order
			#push @Stack,[$CdLvl,$dir_name,$FN,$sub_nlink];
			splice @Stack, $stack_top, 0,
			         [$CdLvl,$dir_name,$FN,$sub_nlink];
		    }
		    else {
			$name = $dir_pref . $FN; # $File::Find::name
			$_= ($no_chdir ? $name : $FN); # $_
			{ $wanted_callback->() }; # protect against wild "next"
		    }
		}
		else {
		    $name = $dir_pref . $FN; # $File::Find::name
		    $_= ($no_chdir ? $name : $FN); # $_
		    { $wanted_callback->() }; # protect against wild "next"
		}
	    }
	}
    }
    continue {
	while ( defined ($SE = pop @Stack) ) {
	    ($Level, $p_dir, $dir_rel, $nlink) = @$SE;
	    if ($CdLvl > $Level && !$no_chdir) {
		my $tmp;
		if ($Is_VMS) {
		    $tmp = '[' . ('-' x ($CdLvl-$Level)) . ']';
		}
		else {
		    $tmp = join('/',('..') x ($CdLvl-$Level));
		}
		die "Can't cd to $tmp from $dir_name"
		    unless chdir ($tmp);
		$CdLvl = $Level;
	    }

	    if ($Is_Win32) {
		$dir_name = ($p_dir =~ m{^(?:\w:[/\\]?|[/\\])$}
		    ? "$p_dir$dir_rel" : "$p_dir/$dir_rel");
		$dir_pref = "$dir_name/";
	    }
	    elsif ($^O eq 'VMS') {
                if ($p_dir =~ m/[\]>]+$/) {
                    $dir_name = $p_dir;
                    $dir_name =~ s/([\]>]+)$/.$dir_rel$1/;
                    $dir_pref = $dir_name;
                }
                else {
                    $dir_name = "$p_dir/$dir_rel";
                    $dir_pref = "$dir_name/";
                }
	    }
	    else {
		$dir_name = ($p_dir eq '/' ? "/$dir_rel" : "$p_dir/$dir_rel");
		$dir_pref = "$dir_name/";
	    }

	    if ( $nlink == -2 ) {
		$name = $dir = $p_dir; # $File::Find::name / dir
                $_ = $File::Find::current_dir;
		$post_process->();		# End-of-directory processing
	    }
	    elsif ( $nlink < 0 ) {  # must be finddepth, report dirname now
		$name = $dir_name;
		if ( substr($name,-2) eq '/.' ) {
		    substr($name, length($name) == 2 ? -1 : -2) = '';
		}
		$dir = $p_dir;
		$_ = ($no_chdir ? $dir_name : $dir_rel );
		if ( substr($_,-2) eq '/.' ) {
		    substr($_, length($_) == 2 ? -1 : -2) = '';
		}
		{ $wanted_callback->() }; # protect against wild "next"
	     }
	     else {
		push @Stack,[$CdLvl,$p_dir,$dir_rel,-1]  if  $bydepth;
		last;
	    }
	}
    }
}


# API:
#  $wanted
#  $dir_loc : absolute location of a dir
#  $p_dir   : "parent directory"
# preconditions:
#  chdir (if not no_chdir) to dir

sub _find_dir_symlnk($$$) {
    my ($wanted, $dir_loc, $p_dir) = @_; # $dir_loc is the absolute directory
    my @Stack;
    my @filenames;
    my $new_loc;
    my $updir_loc = $dir_loc; # untainted parent directory
    my $SE = [];
    my $dir_name = $p_dir;
    my $dir_pref;
    my $loc_pref;
    my $dir_rel = $File::Find::current_dir;
    my $byd_flag; # flag for pending stack entry if $bydepth
    my $tainted = 0;
    my $ok = 1;

    $dir_pref = ( $p_dir   eq '/' ? '/' : "$p_dir/" );
    $loc_pref = ( $dir_loc eq '/' ? '/' : "$dir_loc/" );

    local ($dir, $name, $fullname, $prune, *DIR);

    unless ($no_chdir) {
	# untaint the topdir
	if (( $untaint ) && (is_tainted($dir_loc) )) {
	    ( $updir_loc ) = $dir_loc =~ m|$untaint_pat|; # parent dir, now untainted
	     # once untainted, $updir_loc is pushed on the stack (as parent directory);
	    # hence, we don't need to untaint the parent directory every time we chdir
	    # to it later
	    unless (defined $updir_loc) {
		if ($untaint_skip == 0) {
		    die "directory $dir_loc is still tainted";
		}
		else {
		    return;
		}
	    }
	}
	$ok = chdir($updir_loc) unless ($p_dir eq $File::Find::current_dir);
	unless ($ok) {
	    warnings::warnif "Can't cd to $updir_loc: $!\n";
	    return;
	}
    }

    push @Stack,[$dir_loc,$updir_loc,$p_dir,$dir_rel,-1]  if  $bydepth;

    while (defined $SE) {

	unless ($bydepth) {
	    # change (back) to parent directory (always untainted)
	    unless ($no_chdir) {
		unless (chdir $updir_loc) {
		    warnings::warnif "Can't cd to $updir_loc: $!\n";
		    next;
		}
	    }
	    $dir= $p_dir; # $File::Find::dir
	    $name= $dir_name; # $File::Find::name
	    $_= ($no_chdir ? $dir_name : $dir_rel ); # $_
	    $fullname= $dir_loc; # $File::Find::fullname
	    # prune may happen here
	    $prune= 0;
	    lstat($_); # make sure  file tests with '_' work
	    { $wanted_callback->() }; # protect against wild "next"
	    next if $prune;
	}

	# change to that directory
	unless ($no_chdir || ($dir_rel eq $File::Find::current_dir)) {
	    $updir_loc = $dir_loc;
	    if ( ($untaint) && (($tainted) || ($tainted = is_tainted($dir_loc) )) ) {
		# untaint $dir_loc, what will be pushed on the stack as (untainted) parent dir
		( $updir_loc ) = $dir_loc =~ m|$untaint_pat|;
		unless (defined $updir_loc) {
		    if ($untaint_skip == 0) {
			die "directory $dir_loc is still tainted";
		    }
		    else {
			next;
		    }
		}
	    }
	    unless (chdir $updir_loc) {
		warnings::warnif "Can't cd to $updir_loc: $!\n";
		next;
	    }
	}

	$dir = $dir_name; # $File::Find::dir

	# Get the list of files in the current directory.
	unless (opendir DIR, ($no_chdir ? $dir_loc : $File::Find::current_dir)) {
	    warnings::warnif "Can't opendir($dir_loc): $!\n";
	    next;
	}
	@filenames = readdir DIR;
	closedir(DIR);

	for my $FN (@filenames) {
	    if ($Is_VMS) {
	    # Big hammer here - Compensate for VMS trailing . and .dir
	    # No win situation until this is changed, but this
	    # will handle the majority of the cases with breaking the fewest.

		$FN =~ s/\.dir\z//i;
		$FN =~ s#\.$## if ($FN ne '.');
	    }
	    next if $FN =~ $File::Find::skip_pattern;

	    # follow symbolic links / do an lstat
	    $new_loc = Follow_SymLink($loc_pref.$FN);

	    # ignore if invalid symlink
	    unless (defined $new_loc) {
	        if (!defined -l _ && $dangling_symlinks) {
	            if (ref $dangling_symlinks eq 'CODE') {
	                $dangling_symlinks->($FN, $dir_pref);
	            } else {
	                warnings::warnif "$dir_pref$FN is a dangling symbolic link\n";
	            }
	        }

	        $fullname = undef;
	        $name = $dir_pref . $FN;
	        $_ = ($no_chdir ? $name : $FN);
	        { $wanted_callback->() };
	        next;
	    }

	    if (-d _) {
		if ($Is_VMS) {
		    $FN =~ s/\.dir\z//i;
		    $FN =~ s#\.$## if ($FN ne '.');
		    $new_loc =~ s/\.dir\z//i;
		    $new_loc =~ s#\.$## if ($new_loc ne '.');
		}
		push @Stack,[$new_loc,$updir_loc,$dir_name,$FN,1];
	    }
	    else {
		$fullname = $new_loc; # $File::Find::fullname
		$name = $dir_pref . $FN; # $File::Find::name
		$_ = ($no_chdir ? $name : $FN); # $_
		{ $wanted_callback->() }; # protect against wild "next"
	    }
	}

    }
    continue {
	while (defined($SE = pop @Stack)) {
	    ($dir_loc, $updir_loc, $p_dir, $dir_rel, $byd_flag) = @$SE;
	    $dir_name = ($p_dir eq '/' ? "/$dir_rel" : "$p_dir/$dir_rel");
	    $dir_pref = "$dir_name/";
	    $loc_pref = "$dir_loc/";
	    if ( $byd_flag < 0 ) {  # must be finddepth, report dirname now
		unless ($no_chdir || ($dir_rel eq $File::Find::current_dir)) {
		    unless (chdir $updir_loc) { # $updir_loc (parent dir) is always untainted
			warnings::warnif "Can't cd to $updir_loc: $!\n";
			next;
		    }
		}
		$fullname = $dir_loc; # $File::Find::fullname
		$name = $dir_name; # $File::Find::name
		if ( substr($name,-2) eq '/.' ) {
		    substr($name, length($name) == 2 ? -1 : -2) = ''; # $File::Find::name
		}
		$dir = $p_dir; # $File::Find::dir
		$_ = ($no_chdir ? $dir_name : $dir_rel); # $_
		if ( substr($_,-2) eq '/.' ) {
		    substr($_, length($_) == 2 ? -1 : -2) = '';
		}

		lstat($_); # make sure file tests with '_' work
		{ $wanted_callback->() }; # protect against wild "next"
	    }
	    else {
		push @Stack,[$dir_loc, $updir_loc, $p_dir, $dir_rel,-1]  if  $bydepth;
		last;
	    }
	}
    }
}


sub wrap_wanted {
    my $wanted = shift;
    if ( ref($wanted) eq 'HASH' ) {
        unless( exists $wanted->{wanted} and ref( $wanted->{wanted} ) eq 'CODE' ) {
            die 'no &wanted subroutine given';
        }
	if ( $wanted->{follow} || $wanted->{follow_fast}) {
	    $wanted->{follow_skip} = 1 unless defined $wanted->{follow_skip};
	}
	if ( $wanted->{untaint} ) {
	    $wanted->{untaint_pattern} = $File::Find::untaint_pattern
		unless defined $wanted->{untaint_pattern};
	    $wanted->{untaint_skip} = 0 unless defined $wanted->{untaint_skip};
	}
	return $wanted;
    }
    elsif( ref( $wanted ) eq 'CODE' ) {
	return { wanted => $wanted };
    }
    else {
       die 'no &wanted subroutine given';
    }
}

sub find {
    my $wanted = shift;
    _find_opt(wrap_wanted($wanted), @_);
}

sub finddepth {
    my $wanted = wrap_wanted(shift);
    $wanted->{bydepth} = 1;
    _find_opt($wanted, @_);
}

# default
$File::Find::skip_pattern    = qr/^\.{1,2}\z/;
$File::Find::untaint_pattern = qr|^([-+@\w./]+)$|;

# These are hard-coded for now, but may move to hint files.
if ($^O eq 'VMS') {
    $Is_VMS = 1;
    $File::Find::dont_use_nlink  = 1;
}
elsif ($^O eq 'MSWin32') {
    $Is_Win32 = 1;
}

# this _should_ work properly on all platforms
# where File::Find can be expected to work
$File::Find::current_dir = File::Spec->curdir || '.';

$File::Find::dont_use_nlink = 1
    if $^O eq 'os2' || $^O eq 'dos' || $^O eq 'amigaos' || $Is_Win32 ||
       $^O eq 'interix' || $^O eq 'cygwin' || $^O eq 'epoc' || $^O eq 'qnx' ||
	   $^O eq 'nto';

# Set dont_use_nlink in your hint file if your system's stat doesn't
# report the number of links in a directory as an indication
# of the number of files.
# See, e.g. hints/machten.sh for MachTen 2.2.
unless ($File::Find::dont_use_nlink) {
    require Config;
    $File::Find::dont_use_nlink = 1 if ($Config::Config{'dont_use_nlink'});
}

# We need a function that checks if a scalar is tainted. Either use the
# Scalar::Util module's tainted() function or our (slower) pure Perl
# fallback is_tainted_pp()
{
    local $@;
    eval { require Scalar::Util };
    *is_tainted = $@ ? \&is_tainted_pp : \&Scalar::Util::tainted;
}

1;
FILE   07d43f51/File/GlobMapper.pm  �#line 1 "/usr/share/perl/5.14/File/GlobMapper.pm"
package File::GlobMapper;

use strict;
use warnings;
use Carp;

our ($CSH_GLOB);

BEGIN
{
    if ($] < 5.006)
    { 
        require File::BSDGlob; import File::BSDGlob qw(:glob) ;
        $CSH_GLOB = File::BSDGlob::GLOB_CSH() ;
        *globber = \&File::BSDGlob::csh_glob;
    }  
    else
    { 
        require File::Glob; import File::Glob qw(:glob) ;
        $CSH_GLOB = File::Glob::GLOB_CSH() ;
        #*globber = \&File::Glob::bsd_glob;
        *globber = \&File::Glob::csh_glob;
    }  
}

our ($Error);

our ($VERSION, @EXPORT_OK);
$VERSION = '1.000';
@EXPORT_OK = qw( globmap );


our ($noPreBS, $metachars, $matchMetaRE, %mapping, %wildCount);
$noPreBS = '(?<!\\\)' ; # no preceding backslash
$metachars = '.*?[](){}';
$matchMetaRE = '[' . quotemeta($metachars) . ']';

%mapping = (
                '*' => '([^/]*)',
                '?' => '([^/])',
                '.' => '\.',
                '[' => '([',
                '(' => '(',
                ')' => ')',
           );

%wildCount = map { $_ => 1 } qw/ * ? . { ( [ /;           

sub globmap ($$;)
{
    my $inputGlob = shift ;
    my $outputGlob = shift ;

    my $obj = new File::GlobMapper($inputGlob, $outputGlob, @_)
        or croak "globmap: $Error" ;
    return $obj->getFileMap();
}

sub new
{
    my $class = shift ;
    my $inputGlob = shift ;
    my $outputGlob = shift ;
    # TODO -- flags needs to default to whatever File::Glob does
    my $flags = shift || $CSH_GLOB ;
    #my $flags = shift ;

    $inputGlob =~ s/^\s*\<\s*//;
    $inputGlob =~ s/\s*\>\s*$//;

    $outputGlob =~ s/^\s*\<\s*//;
    $outputGlob =~ s/\s*\>\s*$//;

    my %object =
            (   InputGlob   => $inputGlob,
                OutputGlob  => $outputGlob,
                GlobFlags   => $flags,
                Braces      => 0,
                WildCount   => 0,
                Pairs       => [],
                Sigil       => '#',
            );

    my $self = bless \%object, ref($class) || $class ;

    $self->_parseInputGlob()
        or return undef ;

    $self->_parseOutputGlob()
        or return undef ;
    
    my @inputFiles = globber($self->{InputGlob}, $flags) ;

    if (GLOB_ERROR)
    {
        $Error = $!;
        return undef ;
    }

    #if (whatever)
    {
        my $missing = grep { ! -e $_ } @inputFiles ;

        if ($missing)
        {
            $Error = "$missing input files do not exist";
            return undef ;
        }
    }

    $self->{InputFiles} = \@inputFiles ;

    $self->_getFiles()
        or return undef ;

    return $self;
}

sub _retError
{
    my $string = shift ;
    $Error = "$string in input fileglob" ;
    return undef ;
}

sub _unmatched
{
    my $delimeter = shift ;

    _retError("Unmatched $delimeter");
    return undef ;
}

sub _parseBit
{
    my $self = shift ;

    my $string = shift ;

    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS(,|$matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};

        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq ',')
        { 
            return _unmatched "("
                if $depth ;
            
            $out .= '|';
        }
        elsif ($2 eq '(')
        { 
            ++ $depth ;
        }
        elsif ($2 eq ')')
        { 
            return _unmatched ")"
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched "[" ;
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched "]" ;
        }
        elsif ($2 eq '{' || $2 eq '}')
        {
            return _retError "Nested {} not allowed" ;
        }
    }

    $out .= quotemeta $string;

    return _unmatched "("
        if $depth ;

    return $out ;
}

sub _parseInputGlob
{
    my $self = shift ;

    my $string = $self->{InputGlob} ;
    my $inGlob = '';

    # Multiple concatenated *'s don't make sense
    #$string =~ s#\*\*+#*# ;

    # TODO -- Allow space to delimit patterns?
    #my @strings = split /\s+/, $string ;
    #for my $str (@strings)
    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS($matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};
        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq '(')
        { 
            ++ $depth ;
        }
        elsif ($2 eq ')')
        { 
            return _unmatched ")"
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/' or '(' or ')'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched "[";
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched "]" ;
        }
        elsif ($2 eq '}')
        {
            return _unmatched "}" ;
        }
        elsif ($2 eq '{')
        {
            # TODO -- check no '/' within the {}
            # TODO -- check for \}  & other \ within the {}

            my $tmp ;
            unless ( $string =~ s/(.*?)$noPreBS\}//)
            {
                return _unmatched "{";
            }
            #$string =~ s#(.*?)\}##;

            #my $alt = join '|', 
            #          map { quotemeta $_ } 
            #          split "$noPreBS,", $1 ;
            my $alt = $self->_parseBit($1);
            defined $alt or return 0 ;
            $out .= "($alt)" ;

            ++ $self->{Braces} ;
        }
    }

    return _unmatched "("
        if $depth ;

    $out .= quotemeta $string ;


    $self->{InputGlob} =~ s/$noPreBS[\(\)]//g;
    $self->{InputPattern} = $out ;

    #print "# INPUT '$self->{InputGlob}' => '$out'\n";

    return 1 ;

}

sub _parseOutputGlob
{
    my $self = shift ;

    my $string = $self->{OutputGlob} ;
    my $maxwild = $self->{WildCount};

    if ($self->{GlobFlags} & GLOB_TILDE)
    #if (1)
    {
        $string =~ s{
              ^ ~             # find a leading tilde
              (               # save this in $1
                  [^/]        # a non-slash character
                        *     # repeated 0 or more times (0 means me)
              )
            }{
              $1
                  ? (getpwnam($1))[7]
                  : ( $ENV{HOME} || $ENV{LOGDIR} )
            }ex;

    }

    # max #1 must be == to max no of '*' in input
    while ( $string =~ m/#(\d)/g )
    {
        croak "Max wild is #$maxwild, you tried #$1"
            if $1 > $maxwild ;
    }

    my $noPreBS = '(?<!\\\)' ; # no preceding backslash
    #warn "noPreBS = '$noPreBS'\n";

    #$string =~ s/${noPreBS}\$(\d)/\${$1}/g;
    $string =~ s/${noPreBS}#(\d)/\${$1}/g;
    $string =~ s#${noPreBS}\*#\${inFile}#g;
    $string = '"' . $string . '"';

    #print "OUTPUT '$self->{OutputGlob}' => '$string'\n";
    $self->{OutputPattern} = $string ;

    return 1 ;
}

sub _getFiles
{
    my $self = shift ;

    my %outInMapping = ();
    my %inFiles = () ;

    foreach my $inFile (@{ $self->{InputFiles} })
    {
        next if $inFiles{$inFile} ++ ;

        my $outFile = $inFile ;

        if ( $inFile =~ m/$self->{InputPattern}/ )
        {
            no warnings 'uninitialized';
            eval "\$outFile = $self->{OutputPattern};" ;

            if (defined $outInMapping{$outFile})
            {
                $Error =  "multiple input files map to one output file";
                return undef ;
            }
            $outInMapping{$outFile} = $inFile;
            push @{ $self->{Pairs} }, [$inFile, $outFile];
        }
    }

    return 1 ;
}

sub getFileMap
{
    my $self = shift ;

    return $self->{Pairs} ;
}

sub getHash
{
    my $self = shift ;

    return { map { $_->[0] => $_->[1] } @{ $self->{Pairs} } } ;
}

1;

__END__

#line 680FILE   3c4e1a38/File/Path.pm  ;#line 1 "/usr/share/perl/5.14/File/Path.pm"
package File::Path;

use 5.005_04;
use strict;

use Cwd 'getcwd';
use File::Basename ();
use File::Spec     ();

BEGIN {
    if ($] < 5.006) {
        # can't say 'opendir my $dh, $dirname'
        # need to initialise $dh
        eval "use Symbol";
    }
}

use Exporter ();
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
$VERSION   = '2.08_01';
@ISA       = qw(Exporter);
@EXPORT    = qw(mkpath rmtree);
@EXPORT_OK = qw(make_path remove_tree);

my $Is_VMS     = $^O eq 'VMS';
my $Is_MacOS   = $^O eq 'MacOS';

# These OSes complain if you want to remove a file that you have no
# write permission to:
my $Force_Writeable = grep {$^O eq $_} qw(amigaos dos epoc MSWin32 MacOS os2);

# Unix-like systems need to stat each directory in order to detect
# race condition. MS-Windows is immune to this particular attack.
my $Need_Stat_Check = !($^O eq 'MSWin32');

sub _carp {
    require Carp;
    goto &Carp::carp;
}

sub _croak {
    require Carp;
    goto &Carp::croak;
}

sub _error {
    my $arg     = shift;
    my $message = shift;
    my $object  = shift;

    if ($arg->{error}) {
        $object = '' unless defined $object;
        $message .= ": $!" if $!;
        push @{${$arg->{error}}}, {$object => $message};
    }
    else {
        _carp(defined($object) ? "$message for $object: $!" : "$message: $!");
    }
}

sub make_path {
    push @_, {} unless @_ and UNIVERSAL::isa($_[-1],'HASH');
    goto &mkpath;
}

sub mkpath {
    my $old_style = !(@_ and UNIVERSAL::isa($_[-1],'HASH'));

    my $arg;
    my $paths;

    if ($old_style) {
        my ($verbose, $mode);
        ($paths, $verbose, $mode) = @_;
        $paths = [$paths] unless UNIVERSAL::isa($paths,'ARRAY');
        $arg->{verbose} = $verbose;
        $arg->{mode}    = defined $mode ? $mode : 0777;
    }
    else {
        $arg = pop @_;
        $arg->{mode}      = delete $arg->{mask} if exists $arg->{mask};
        $arg->{mode}      = 0777 unless exists $arg->{mode};
        ${$arg->{error}}  = [] if exists $arg->{error};
        $arg->{owner}     = delete $arg->{user} if exists $arg->{user};
        $arg->{owner}     = delete $arg->{uid}  if exists $arg->{uid};
        if (exists $arg->{owner} and $arg->{owner} =~ /\D/) {
            my $uid = (getpwnam $arg->{owner})[2];
            if (defined $uid) {
                $arg->{owner} = $uid;
            }
            else {
                _error($arg, "unable to map $arg->{owner} to a uid, ownership not changed");
                delete $arg->{owner};
            }
        }
        if (exists $arg->{group} and $arg->{group} =~ /\D/) {
            my $gid = (getgrnam $arg->{group})[2];
            if (defined $gid) {
                $arg->{group} = $gid;
            }
            else {
                _error($arg, "unable to map $arg->{group} to a gid, group ownership not changed");
                delete $arg->{group};
            }
        }
        if (exists $arg->{owner} and not exists $arg->{group}) {
            $arg->{group} = -1; # chown will leave group unchanged
        }
        if (exists $arg->{group} and not exists $arg->{owner}) {
            $arg->{owner} = -1; # chown will leave owner unchanged
        }
        $paths = [@_];
    }
    return _mkpath($arg, $paths);
}

sub _mkpath {
    my $arg   = shift;
    my $paths = shift;

    my(@created,$path);
    foreach $path (@$paths) {
        next unless defined($path) and length($path);
        $path .= '/' if $^O eq 'os2' and $path =~ /^\w:\z/s; # feature of CRT 
        # Logic wants Unix paths, so go with the flow.
        if ($Is_VMS) {
            next if $path eq '/';
            $path = VMS::Filespec::unixify($path);
        }
        next if -d $path;
        my $parent = File::Basename::dirname($path);
        unless (-d $parent or $path eq $parent) {
            push(@created,_mkpath($arg, [$parent]));
        }
        print "mkdir $path\n" if $arg->{verbose};
        if (mkdir($path,$arg->{mode})) {
            push(@created, $path);
            if (exists $arg->{owner}) {
				# NB: $arg->{group} guaranteed to be set during initialisation
                if (!chown $arg->{owner}, $arg->{group}, $path) {
                    _error($arg, "Cannot change ownership of $path to $arg->{owner}:$arg->{group}");
                }
            }
        }
        else {
            my $save_bang = $!;
            my ($e, $e1) = ($save_bang, $^E);
            $e .= "; $e1" if $e ne $e1;
            # allow for another process to have created it meanwhile
            if (!-d $path) {
                $! = $save_bang;
                if ($arg->{error}) {
                    push @{${$arg->{error}}}, {$path => $e};
                }
                else {
                    _croak("mkdir $path: $e");
                }
            }
        }
    }
    return @created;
}

sub remove_tree {
    push @_, {} unless @_ and UNIVERSAL::isa($_[-1],'HASH');
    goto &rmtree;
}

sub _is_subdir {
    my($dir, $test) = @_;

    my($dv, $dd) = File::Spec->splitpath($dir, 1);
    my($tv, $td) = File::Spec->splitpath($test, 1);

    # not on same volume
    return 0 if $dv ne $tv;

    my @d = File::Spec->splitdir($dd);
    my @t = File::Spec->splitdir($td);

    # @t can't be a subdir if it's shorter than @d
    return 0 if @t < @d;

    return join('/', @d) eq join('/', splice @t, 0, +@d);
}

sub rmtree {
    my $old_style = !(@_ and UNIVERSAL::isa($_[-1],'HASH'));

    my $arg;
    my $paths;

    if ($old_style) {
        my ($verbose, $safe);
        ($paths, $verbose, $safe) = @_;
        $arg->{verbose} = $verbose;
        $arg->{safe}    = defined $safe    ? $safe    : 0;

        if (defined($paths) and length($paths)) {
            $paths = [$paths] unless UNIVERSAL::isa($paths,'ARRAY');
        }
        else {
            _carp ("No root path(s) specified\n");
            return 0;
        }
    }
    else {
        $arg = pop @_;
        ${$arg->{error}}  = [] if exists $arg->{error};
        ${$arg->{result}} = [] if exists $arg->{result};
        $paths = [@_];
    }

    $arg->{prefix} = '';
    $arg->{depth}  = 0;

    my @clean_path;
    $arg->{cwd} = getcwd() or do {
        _error($arg, "cannot fetch initial working directory");
        return 0;
    };
    for ($arg->{cwd}) { /\A(.*)\Z/; $_ = $1 } # untaint

    for my $p (@$paths) {
        # need to fixup case and map \ to / on Windows
        my $ortho_root = $^O eq 'MSWin32' ? _slash_lc($p)          : $p;
        my $ortho_cwd  = $^O eq 'MSWin32' ? _slash_lc($arg->{cwd}) : $arg->{cwd};
        my $ortho_root_length = length($ortho_root);
        $ortho_root_length-- if $^O eq 'VMS'; # don't compare '.' with ']'
        if ($ortho_root_length && _is_subdir($ortho_root, $ortho_cwd)) {
            local $! = 0;
            _error($arg, "cannot remove path when cwd is $arg->{cwd}", $p);
            next;
        }

        if ($Is_MacOS) {
            $p  = ":$p" unless $p =~ /:/;
            $p .= ":"   unless $p =~ /:\z/;
        }
        elsif ($^O eq 'MSWin32') {
            $p =~ s{[/\\]\z}{};
        }
        else {
            $p =~ s{/\z}{};
        }
        push @clean_path, $p;
    }

    @{$arg}{qw(device inode perm)} = (lstat $arg->{cwd})[0,1] or do {
        _error($arg, "cannot stat initial working directory", $arg->{cwd});
        return 0;
    };

    return _rmtree($arg, \@clean_path);
}

sub _rmtree {
    my $arg   = shift;
    my $paths = shift;

    my $count  = 0;
    my $curdir = File::Spec->curdir();
    my $updir  = File::Spec->updir();

    my (@files, $root);
    ROOT_DIR:
    foreach $root (@$paths) {
        # since we chdir into each directory, it may not be obvious
        # to figure out where we are if we generate a message about
        # a file name. We therefore construct a semi-canonical
        # filename, anchored from the directory being unlinked (as
        # opposed to being truly canonical, anchored from the root (/).

        my $canon = $arg->{prefix}
            ? File::Spec->catfile($arg->{prefix}, $root)
            : $root
        ;

        my ($ldev, $lino, $perm) = (lstat $root)[0,1,2] or next ROOT_DIR;

        if ( -d _ ) {
            $root = VMS::Filespec::vmspath(VMS::Filespec::pathify($root)) if $Is_VMS;

            if (!chdir($root)) {
                # see if we can escalate privileges to get in
                # (e.g. funny protection mask such as -w- instead of rwx)
                $perm &= 07777;
                my $nperm = $perm | 0700;
                if (!($arg->{safe} or $nperm == $perm or chmod($nperm, $root))) {
                    _error($arg, "cannot make child directory read-write-exec", $canon);
                    next ROOT_DIR;
                }
                elsif (!chdir($root)) {
                    _error($arg, "cannot chdir to child", $canon);
                    next ROOT_DIR;
                }
            }

            my ($cur_dev, $cur_inode, $perm) = (stat $curdir)[0,1,2] or do {
                _error($arg, "cannot stat current working directory", $canon);
                next ROOT_DIR;
            };

            if ($Need_Stat_Check) {
                ($ldev eq $cur_dev and $lino eq $cur_inode)
                    or _croak("directory $canon changed before chdir, expected dev=$ldev ino=$lino, actual dev=$cur_dev ino=$cur_inode, aborting.");
            }

            $perm &= 07777; # don't forget setuid, setgid, sticky bits
            my $nperm = $perm | 0700;

            # notabene: 0700 is for making readable in the first place,
            # it's also intended to change it to writable in case we have
            # to recurse in which case we are better than rm -rf for 
            # subtrees with strange permissions

            if (!($arg->{safe} or $nperm == $perm or chmod($nperm, $curdir))) {
                _error($arg, "cannot make directory read+writeable", $canon);
                $nperm = $perm;
            }

            my $d;
            $d = gensym() if $] < 5.006;
            if (!opendir $d, $curdir) {
                _error($arg, "cannot opendir", $canon);
                @files = ();
            }
            else {
                no strict 'refs';
                if (!defined ${"\cTAINT"} or ${"\cTAINT"}) {
                    # Blindly untaint dir names if taint mode is
                    # active, or any perl < 5.006
                    @files = map { /\A(.*)\z/s; $1 } readdir $d;
                }
                else {
                    @files = readdir $d;
                }
                closedir $d;
            }

            if ($Is_VMS) {
                # Deleting large numbers of files from VMS Files-11
                # filesystems is faster if done in reverse ASCIIbetical order.
                # include '.' to '.;' from blead patch #31775
                @files = map {$_ eq '.' ? '.;' : $_} reverse @files;
            }

            @files = grep {$_ ne $updir and $_ ne $curdir} @files;

            if (@files) {
                # remove the contained files before the directory itself
                my $narg = {%$arg};
                @{$narg}{qw(device inode cwd prefix depth)}
                    = ($cur_dev, $cur_inode, $updir, $canon, $arg->{depth}+1);
                $count += _rmtree($narg, \@files);
            }

            # restore directory permissions of required now (in case the rmdir
            # below fails), while we are still in the directory and may do so
            # without a race via '.'
            if ($nperm != $perm and not chmod($perm, $curdir)) {
                _error($arg, "cannot reset chmod", $canon);
            }

            # don't leave the client code in an unexpected directory
            chdir($arg->{cwd})
                or _croak("cannot chdir to $arg->{cwd} from $canon: $!, aborting.");

            # ensure that a chdir upwards didn't take us somewhere other
            # than we expected (see CVE-2002-0435)
            ($cur_dev, $cur_inode) = (stat $curdir)[0,1]
                or _croak("cannot stat prior working directory $arg->{cwd}: $!, aborting.");

            if ($Need_Stat_Check) {
                ($arg->{device} eq $cur_dev and $arg->{inode} eq $cur_inode)
                    or _croak("previous directory $arg->{cwd} changed before entering $canon, expected dev=$ldev ino=$lino, actual dev=$cur_dev ino=$cur_inode, aborting.");
            }

            if ($arg->{depth} or !$arg->{keep_root}) {
                if ($arg->{safe} &&
                    ($Is_VMS ? !&VMS::Filespec::candelete($root) : !-w $root)) {
                    print "skipped $root\n" if $arg->{verbose};
                    next ROOT_DIR;
                }
                if ($Force_Writeable and !chmod $perm | 0700, $root) {
                    _error($arg, "cannot make directory writeable", $canon);
                }
                print "rmdir $root\n" if $arg->{verbose};
                if (rmdir $root) {
                    push @{${$arg->{result}}}, $root if $arg->{result};
                    ++$count;
                }
                else {
                    _error($arg, "cannot remove directory", $canon);
                    if ($Force_Writeable && !chmod($perm, ($Is_VMS ? VMS::Filespec::fileify($root) : $root))
                    ) {
                        _error($arg, sprintf("cannot restore permissions to 0%o",$perm), $canon);
                    }
                }
            }
        }
        else {
            # not a directory
            $root = VMS::Filespec::vmsify("./$root")
                if $Is_VMS
                   && !File::Spec->file_name_is_absolute($root)
                   && ($root !~ m/(?<!\^)[\]>]+/);  # not already in VMS syntax

            if ($arg->{safe} &&
                ($Is_VMS ? !&VMS::Filespec::candelete($root)
                         : !(-l $root || -w $root)))
            {
                print "skipped $root\n" if $arg->{verbose};
                next ROOT_DIR;
            }

            my $nperm = $perm & 07777 | 0600;
            if ($Force_Writeable and $nperm != $perm and not chmod $nperm, $root) {
                _error($arg, "cannot make file writeable", $canon);
            }
            print "unlink $canon\n" if $arg->{verbose};
            # delete all versions under VMS
            for (;;) {
                if (unlink $root) {
                    push @{${$arg->{result}}}, $root if $arg->{result};
                }
                else {
                    _error($arg, "cannot unlink file", $canon);
                    $Force_Writeable and chmod($perm, $root) or
                        _error($arg, sprintf("cannot restore permissions to 0%o",$perm), $canon);
                    last;
                }
                ++$count;
                last unless $Is_VMS && lstat $root;
            }
        }
    }
    return $count;
}

sub _slash_lc {
    # fix up slashes and case on MSWin32 so that we can determine that
    # c:\path\to\dir is underneath C:/Path/To
    my $path = shift;
    $path =~ tr{\\}{/};
    return lc($path);
}

1;
__END__

#line 982
FILE   84a91b21/File/Temp.pm  �9#line 1 "/usr/share/perl/5.14/File/Temp.pm"
package File::Temp;

#line 138

# 5.6.0 gives us S_IWOTH, S_IWGRP, our and auto-vivifying filehandls
# People would like a version on 5.004 so give them what they want :-)
use 5.004;
use strict;
use Carp;
use File::Spec 0.8;
use File::Path qw/ rmtree /;
use Fcntl 1.03;
use IO::Seekable;               # For SEEK_*
use Errno;
require VMS::Stdio if $^O eq 'VMS';

# pre-emptively load Carp::Heavy. If we don't when we run out of file
# handles and attempt to call croak() we get an error message telling
# us that Carp::Heavy won't load rather than an error telling us we
# have run out of file handles. We either preload croak() or we
# switch the calls to croak from _gettemp() to use die.
eval { require Carp::Heavy; };

# Need the Symbol package if we are running older perl
require Symbol if $] < 5.006;

### For the OO interface
use base qw/ IO::Handle IO::Seekable /;
use overload '""' => "STRINGIFY", fallback => 1;

# use 'our' on v5.6.0
use vars qw($VERSION @EXPORT_OK %EXPORT_TAGS $DEBUG $KEEP_ALL);

$DEBUG = 0;
$KEEP_ALL = 0;

# We are exporting functions

use base qw/Exporter/;

# Export list - to allow fine tuning of export table

@EXPORT_OK = qw{
                 tempfile
                 tempdir
                 tmpnam
                 tmpfile
                 mktemp
                 mkstemp
                 mkstemps
                 mkdtemp
                 unlink0
                 cleanup
                 SEEK_SET
                 SEEK_CUR
                 SEEK_END
             };

# Groups of functions for export

%EXPORT_TAGS = (
                'POSIX' => [qw/ tmpnam tmpfile /],
                'mktemp' => [qw/ mktemp mkstemp mkstemps mkdtemp/],
                'seekable' => [qw/ SEEK_SET SEEK_CUR SEEK_END /],
               );

# add contents of these tags to @EXPORT
Exporter::export_tags('POSIX','mktemp','seekable');

# Version number

$VERSION = '0.22';

# This is a list of characters that can be used in random filenames

my @CHARS = (qw/ A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
                 a b c d e f g h i j k l m n o p q r s t u v w x y z
                 0 1 2 3 4 5 6 7 8 9 _
               /);

# Maximum number of tries to make a temp file before failing

use constant MAX_TRIES => 1000;

# Minimum number of X characters that should be in a template
use constant MINX => 4;

# Default template when no template supplied

use constant TEMPXXX => 'X' x 10;

# Constants for the security level

use constant STANDARD => 0;
use constant MEDIUM   => 1;
use constant HIGH     => 2;

# OPENFLAGS. If we defined the flag to use with Sysopen here this gives
# us an optimisation when many temporary files are requested

my $OPENFLAGS = O_CREAT | O_EXCL | O_RDWR;
my $LOCKFLAG;

unless ($^O eq 'MacOS') {
  for my $oflag (qw/ NOFOLLOW BINARY LARGEFILE NOINHERIT /) {
    my ($bit, $func) = (0, "Fcntl::O_" . $oflag);
    no strict 'refs';
    $OPENFLAGS |= $bit if eval {
      # Make sure that redefined die handlers do not cause problems
      # e.g. CGI::Carp
      local $SIG{__DIE__} = sub {};
      local $SIG{__WARN__} = sub {};
      $bit = &$func();
      1;
    };
  }
  # Special case O_EXLOCK
  $LOCKFLAG = eval {
    local $SIG{__DIE__} = sub {};
    local $SIG{__WARN__} = sub {};
    &Fcntl::O_EXLOCK();
  };
}

# On some systems the O_TEMPORARY flag can be used to tell the OS
# to automatically remove the file when it is closed. This is fine
# in most cases but not if tempfile is called with UNLINK=>0 and
# the filename is requested -- in the case where the filename is to
# be passed to another routine. This happens on windows. We overcome
# this by using a second open flags variable

my $OPENTEMPFLAGS = $OPENFLAGS;
unless ($^O eq 'MacOS') {
  for my $oflag (qw/ TEMPORARY /) {
    my ($bit, $func) = (0, "Fcntl::O_" . $oflag);
    local($@);
    no strict 'refs';
    $OPENTEMPFLAGS |= $bit if eval {
      # Make sure that redefined die handlers do not cause problems
      # e.g. CGI::Carp
      local $SIG{__DIE__} = sub {};
      local $SIG{__WARN__} = sub {};
      $bit = &$func();
      1;
    };
  }
}

# Private hash tracking which files have been created by each process id via the OO interface
my %FILES_CREATED_BY_OBJECT;

# INTERNAL ROUTINES - not to be used outside of package

# Generic routine for getting a temporary filename
# modelled on OpenBSD _gettemp() in mktemp.c

# The template must contain X's that are to be replaced
# with the random values

#  Arguments:

#  TEMPLATE   - string containing the XXXXX's that is converted
#           to a random filename and opened if required

# Optionally, a hash can also be supplied containing specific options
#   "open" => if true open the temp file, else just return the name
#             default is 0
#   "mkdir"=> if true, we are creating a temp directory rather than tempfile
#             default is 0
#   "suffixlen" => number of characters at end of PATH to be ignored.
#                  default is 0.
#   "unlink_on_close" => indicates that, if possible,  the OS should remove
#                        the file as soon as it is closed. Usually indicates
#                        use of the O_TEMPORARY flag to sysopen.
#                        Usually irrelevant on unix
#   "use_exlock" => Indicates that O_EXLOCK should be used. Default is true.

# Optionally a reference to a scalar can be passed into the function
# On error this will be used to store the reason for the error
#   "ErrStr"  => \$errstr

# "open" and "mkdir" can not both be true
# "unlink_on_close" is not used when "mkdir" is true.

# The default options are equivalent to mktemp().

# Returns:
#   filehandle - open file handle (if called with doopen=1, else undef)
#   temp name  - name of the temp file or directory

# For example:
#   ($fh, $name) = _gettemp($template, "open" => 1);

# for the current version, failures are associated with
# stored in an error string and returned to give the reason whilst debugging
# This routine is not called by any external function
sub _gettemp {

  croak 'Usage: ($fh, $name) = _gettemp($template, OPTIONS);'
    unless scalar(@_) >= 1;

  # the internal error string - expect it to be overridden
  # Need this in case the caller decides not to supply us a value
  # need an anonymous scalar
  my $tempErrStr;

  # Default options
  my %options = (
                 "open" => 0,
                 "mkdir" => 0,
                 "suffixlen" => 0,
                 "unlink_on_close" => 0,
                 "use_exlock" => 1,
                 "ErrStr" => \$tempErrStr,
                );

  # Read the template
  my $template = shift;
  if (ref($template)) {
    # Use a warning here since we have not yet merged ErrStr
    carp "File::Temp::_gettemp: template must not be a reference";
    return ();
  }

  # Check that the number of entries on stack are even
  if (scalar(@_) % 2 != 0) {
    # Use a warning here since we have not yet merged ErrStr
    carp "File::Temp::_gettemp: Must have even number of options";
    return ();
  }

  # Read the options and merge with defaults
  %options = (%options, @_)  if @_;

  # Make sure the error string is set to undef
  ${$options{ErrStr}} = undef;

  # Can not open the file and make a directory in a single call
  if ($options{"open"} && $options{"mkdir"}) {
    ${$options{ErrStr}} = "doopen and domkdir can not both be true\n";
    return ();
  }

  # Find the start of the end of the  Xs (position of last X)
  # Substr starts from 0
  my $start = length($template) - 1 - $options{"suffixlen"};

  # Check that we have at least MINX x X (e.g. 'XXXX") at the end of the string
  # (taking suffixlen into account). Any fewer is insecure.

  # Do it using substr - no reason to use a pattern match since
  # we know where we are looking and what we are looking for

  if (substr($template, $start - MINX + 1, MINX) ne 'X' x MINX) {
    ${$options{ErrStr}} = "The template must end with at least ".
      MINX . " 'X' characters\n";
    return ();
  }

  # Replace all the X at the end of the substring with a
  # random character or just all the XX at the end of a full string.
  # Do it as an if, since the suffix adjusts which section to replace
  # and suffixlen=0 returns nothing if used in the substr directly
  # and generate a full path from the template

  my $path = _replace_XX($template, $options{"suffixlen"});


  # Split the path into constituent parts - eventually we need to check
  # whether the directory exists
  # We need to know whether we are making a temp directory
  # or a tempfile

  my ($volume, $directories, $file);
  my $parent;                   # parent directory
  if ($options{"mkdir"}) {
    # There is no filename at the end
    ($volume, $directories, $file) = File::Spec->splitpath( $path, 1);

    # The parent is then $directories without the last directory
    # Split the directory and put it back together again
    my @dirs = File::Spec->splitdir($directories);

    # If @dirs only has one entry (i.e. the directory template) that means
    # we are in the current directory
    if ($#dirs == 0) {
      $parent = File::Spec->curdir;
    } else {

      if ($^O eq 'VMS') {     # need volume to avoid relative dir spec
        $parent = File::Spec->catdir($volume, @dirs[0..$#dirs-1]);
        $parent = 'sys$disk:[]' if $parent eq '';
      } else {

        # Put it back together without the last one
        $parent = File::Spec->catdir(@dirs[0..$#dirs-1]);

        # ...and attach the volume (no filename)
        $parent = File::Spec->catpath($volume, $parent, '');
      }

    }

  } else {

    # Get rid of the last filename (use File::Basename for this?)
    ($volume, $directories, $file) = File::Spec->splitpath( $path );

    # Join up without the file part
    $parent = File::Spec->catpath($volume,$directories,'');

    # If $parent is empty replace with curdir
    $parent = File::Spec->curdir
      unless $directories ne '';

  }

  # Check that the parent directories exist
  # Do this even for the case where we are simply returning a name
  # not a file -- no point returning a name that includes a directory
  # that does not exist or is not writable

  unless (-e $parent) {
    ${$options{ErrStr}} = "Parent directory ($parent) does not exist";
    return ();
  }
  unless (-d $parent) {
    ${$options{ErrStr}} = "Parent directory ($parent) is not a directory";
    return ();
  }

  # Check the stickiness of the directory and chown giveaway if required
  # If the directory is world writable the sticky bit
  # must be set

  if (File::Temp->safe_level == MEDIUM) {
    my $safeerr;
    unless (_is_safe($parent,\$safeerr)) {
      ${$options{ErrStr}} = "Parent directory ($parent) is not safe ($safeerr)";
      return ();
    }
  } elsif (File::Temp->safe_level == HIGH) {
    my $safeerr;
    unless (_is_verysafe($parent, \$safeerr)) {
      ${$options{ErrStr}} = "Parent directory ($parent) is not safe ($safeerr)";
      return ();
    }
  }


  # Now try MAX_TRIES time to open the file
  for (my $i = 0; $i < MAX_TRIES; $i++) {

    # Try to open the file if requested
    if ($options{"open"}) {
      my $fh;

      # If we are running before perl5.6.0 we can not auto-vivify
      if ($] < 5.006) {
        $fh = &Symbol::gensym;
      }

      # Try to make sure this will be marked close-on-exec
      # XXX: Win32 doesn't respect this, nor the proper fcntl,
      #      but may have O_NOINHERIT. This may or may not be in Fcntl.
      local $^F = 2;

      # Attempt to open the file
      my $open_success = undef;
      if ( $^O eq 'VMS' and $options{"unlink_on_close"} && !$KEEP_ALL) {
        # make it auto delete on close by setting FAB$V_DLT bit
        $fh = VMS::Stdio::vmssysopen($path, $OPENFLAGS, 0600, 'fop=dlt');
        $open_success = $fh;
      } else {
        my $flags = ( ($options{"unlink_on_close"} && !$KEEP_ALL) ?
                      $OPENTEMPFLAGS :
                      $OPENFLAGS );
        $flags |= $LOCKFLAG if (defined $LOCKFLAG && $options{use_exlock});
        $open_success = sysopen($fh, $path, $flags, 0600);
      }
      if ( $open_success ) {

        # in case of odd umask force rw
        chmod(0600, $path);

        # Opened successfully - return file handle and name
        return ($fh, $path);

      } else {

        # Error opening file - abort with error
        # if the reason was anything but EEXIST
        unless ($!{EEXIST}) {
          ${$options{ErrStr}} = "Could not create temp file $path: $!";
          return ();
        }

        # Loop round for another try

      }
    } elsif ($options{"mkdir"}) {

      # Open the temp directory
      if (mkdir( $path, 0700)) {
        # in case of odd umask
        chmod(0700, $path);

        return undef, $path;
      } else {

        # Abort with error if the reason for failure was anything
        # except EEXIST
        unless ($!{EEXIST}) {
          ${$options{ErrStr}} = "Could not create directory $path: $!";
          return ();
        }

        # Loop round for another try

      }

    } else {

      # Return true if the file can not be found
      # Directory has been checked previously

      return (undef, $path) unless -e $path;

      # Try again until MAX_TRIES

    }

    # Did not successfully open the tempfile/dir
    # so try again with a different set of random letters
    # No point in trying to increment unless we have only
    # 1 X say and the randomness could come up with the same
    # file MAX_TRIES in a row.

    # Store current attempt - in principal this implies that the
    # 3rd time around the open attempt that the first temp file
    # name could be generated again. Probably should store each
    # attempt and make sure that none are repeated

    my $original = $path;
    my $counter = 0;            # Stop infinite loop
    my $MAX_GUESS = 50;

    do {

      # Generate new name from original template
      $path = _replace_XX($template, $options{"suffixlen"});

      $counter++;

    } until ($path ne $original || $counter > $MAX_GUESS);

    # Check for out of control looping
    if ($counter > $MAX_GUESS) {
      ${$options{ErrStr}} = "Tried to get a new temp name different to the previous value $MAX_GUESS times.\nSomething wrong with template?? ($template)";
      return ();
    }

  }

  # If we get here, we have run out of tries
  ${ $options{ErrStr} } = "Have exceeded the maximum number of attempts ("
    . MAX_TRIES . ") to open temp file/dir";

  return ();

}

# Internal routine to replace the XXXX... with random characters
# This has to be done by _gettemp() every time it fails to
# open a temp file/dir

# Arguments:  $template (the template with XXX),
#             $ignore   (number of characters at end to ignore)

# Returns:    modified template

sub _replace_XX {

  croak 'Usage: _replace_XX($template, $ignore)'
    unless scalar(@_) == 2;

  my ($path, $ignore) = @_;

  # Do it as an if, since the suffix adjusts which section to replace
  # and suffixlen=0 returns nothing if used in the substr directly
  # Alternatively, could simply set $ignore to length($path)-1
  # Don't want to always use substr when not required though.
  my $end = ( $] >= 5.006 ? "\\z" : "\\Z" );

  if ($ignore) {
    substr($path, 0, - $ignore) =~ s/X(?=X*$end)/$CHARS[ int( rand( @CHARS ) ) ]/ge;
  } else {
    $path =~ s/X(?=X*$end)/$CHARS[ int( rand( @CHARS ) ) ]/ge;
  }
  return $path;
}

# Internal routine to force a temp file to be writable after
# it is created so that we can unlink it. Windows seems to occassionally
# force a file to be readonly when written to certain temp locations
sub _force_writable {
  my $file = shift;
  chmod 0600, $file;
}


# internal routine to check to see if the directory is safe
# First checks to see if the directory is not owned by the
# current user or root. Then checks to see if anyone else
# can write to the directory and if so, checks to see if
# it has the sticky bit set

# Will not work on systems that do not support sticky bit

#Args:  directory path to check
#       Optionally: reference to scalar to contain error message
# Returns true if the path is safe and false otherwise.
# Returns undef if can not even run stat() on the path

# This routine based on version written by Tom Christiansen

# Presumably, by the time we actually attempt to create the
# file or directory in this directory, it may not be safe
# anymore... Have to run _is_safe directly after the open.

sub _is_safe {

  my $path = shift;
  my $err_ref = shift;

  # Stat path
  my @info = stat($path);
  unless (scalar(@info)) {
    $$err_ref = "stat(path) returned no values";
    return 0;
  }
  ;
  return 1 if $^O eq 'VMS';     # owner delete control at file level

  # Check to see whether owner is neither superuser (or a system uid) nor me
  # Use the effective uid from the $> variable
  # UID is in [4]
  if ($info[4] > File::Temp->top_system_uid() && $info[4] != $>) {

    Carp::cluck(sprintf "uid=$info[4] topuid=%s euid=$> path='$path'",
                File::Temp->top_system_uid());

    $$err_ref = "Directory owned neither by root nor the current user"
      if ref($err_ref);
    return 0;
  }

  # check whether group or other can write file
  # use 066 to detect either reading or writing
  # use 022 to check writability
  # Do it with S_IWOTH and S_IWGRP for portability (maybe)
  # mode is in info[2]
  if (($info[2] & &Fcntl::S_IWGRP) ||  # Is group writable?
      ($info[2] & &Fcntl::S_IWOTH) ) { # Is world writable?
    # Must be a directory
    unless (-d $path) {
      $$err_ref = "Path ($path) is not a directory"
        if ref($err_ref);
      return 0;
    }
    # Must have sticky bit set
    unless (-k $path) {
      $$err_ref = "Sticky bit not set on $path when dir is group|world writable"
        if ref($err_ref);
      return 0;
    }
  }

  return 1;
}

# Internal routine to check whether a directory is safe
# for temp files. Safer than _is_safe since it checks for
# the possibility of chown giveaway and if that is a possibility
# checks each directory in the path to see if it is safe (with _is_safe)

# If _PC_CHOWN_RESTRICTED is not set, does the full test of each
# directory anyway.

# Takes optional second arg as scalar ref to error reason

sub _is_verysafe {

  # Need POSIX - but only want to bother if really necessary due to overhead
  require POSIX;

  my $path = shift;
  print "_is_verysafe testing $path\n" if $DEBUG;
  return 1 if $^O eq 'VMS';     # owner delete control at file level

  my $err_ref = shift;

  # Should Get the value of _PC_CHOWN_RESTRICTED if it is defined
  # and If it is not there do the extensive test
  local($@);
  my $chown_restricted;
  $chown_restricted = &POSIX::_PC_CHOWN_RESTRICTED()
    if eval { &POSIX::_PC_CHOWN_RESTRICTED(); 1};

  # If chown_resticted is set to some value we should test it
  if (defined $chown_restricted) {

    # Return if the current directory is safe
    return _is_safe($path,$err_ref) if POSIX::sysconf( $chown_restricted );

  }

  # To reach this point either, the _PC_CHOWN_RESTRICTED symbol
  # was not avialable or the symbol was there but chown giveaway
  # is allowed. Either way, we now have to test the entire tree for
  # safety.

  # Convert path to an absolute directory if required
  unless (File::Spec->file_name_is_absolute($path)) {
    $path = File::Spec->rel2abs($path);
  }

  # Split directory into components - assume no file
  my ($volume, $directories, undef) = File::Spec->splitpath( $path, 1);

  # Slightly less efficient than having a function in File::Spec
  # to chop off the end of a directory or even a function that
  # can handle ../ in a directory tree
  # Sometimes splitdir() returns a blank at the end
  # so we will probably check the bottom directory twice in some cases
  my @dirs = File::Spec->splitdir($directories);

  # Concatenate one less directory each time around
  foreach my $pos (0.. $#dirs) {
    # Get a directory name
    my $dir = File::Spec->catpath($volume,
                                  File::Spec->catdir(@dirs[0.. $#dirs - $pos]),
                                  ''
                                 );

    print "TESTING DIR $dir\n" if $DEBUG;

    # Check the directory
    return 0 unless _is_safe($dir,$err_ref);

  }

  return 1;
}



# internal routine to determine whether unlink works on this
# platform for files that are currently open.
# Returns true if we can, false otherwise.

# Currently WinNT, OS/2 and VMS can not unlink an opened file
# On VMS this is because the O_EXCL flag is used to open the
# temporary file. Currently I do not know enough about the issues
# on VMS to decide whether O_EXCL is a requirement.

sub _can_unlink_opened_file {

  if ($^O eq 'MSWin32' || $^O eq 'os2' || $^O eq 'VMS' || $^O eq 'dos' || $^O eq 'MacOS') {
    return 0;
  } else {
    return 1;
  }

}

# internal routine to decide which security levels are allowed
# see safe_level() for more information on this

# Controls whether the supplied security level is allowed

#   $cando = _can_do_level( $level )

sub _can_do_level {

  # Get security level
  my $level = shift;

  # Always have to be able to do STANDARD
  return 1 if $level == STANDARD;

  # Currently, the systems that can do HIGH or MEDIUM are identical
  if ( $^O eq 'MSWin32' || $^O eq 'os2' || $^O eq 'cygwin' || $^O eq 'dos' || $^O eq 'MacOS' || $^O eq 'mpeix') {
    return 0;
  } else {
    return 1;
  }

}

# This routine sets up a deferred unlinking of a specified
# filename and filehandle. It is used in the following cases:
#  - Called by unlink0 if an opened file can not be unlinked
#  - Called by tempfile() if files are to be removed on shutdown
#  - Called by tempdir() if directories are to be removed on shutdown

# Arguments:
#   _deferred_unlink( $fh, $fname, $isdir );
#
#   - filehandle (so that it can be expclicitly closed if open
#   - filename   (the thing we want to remove)
#   - isdir      (flag to indicate that we are being given a directory)
#                 [and hence no filehandle]

# Status is not referred to since all the magic is done with an END block

{
  # Will set up two lexical variables to contain all the files to be
  # removed. One array for files, another for directories They will
  # only exist in this block.

  #  This means we only have to set up a single END block to remove
  #  all files. 

  # in order to prevent child processes inadvertently deleting the parent
  # temp files we use a hash to store the temp files and directories
  # created by a particular process id.

  # %files_to_unlink contains values that are references to an array of
  # array references containing the filehandle and filename associated with
  # the temp file.
  my (%files_to_unlink, %dirs_to_unlink);

  # Set up an end block to use these arrays
  END {
    local($., $@, $!, $^E, $?);
    cleanup();
  }

  # Cleanup function. Always triggered on END but can be invoked
  # manually.
  sub cleanup {
    if (!$KEEP_ALL) {
      # Files
      my @files = (exists $files_to_unlink{$$} ?
                   @{ $files_to_unlink{$$} } : () );
      foreach my $file (@files) {
        # close the filehandle without checking its state
        # in order to make real sure that this is closed
        # if its already closed then I dont care about the answer
        # probably a better way to do this
        close($file->[0]);      # file handle is [0]

        if (-f $file->[1]) {       # file name is [1]
          _force_writable( $file->[1] ); # for windows
          unlink $file->[1] or warn "Error removing ".$file->[1];
        }
      }
      # Dirs
      my @dirs = (exists $dirs_to_unlink{$$} ?
                  @{ $dirs_to_unlink{$$} } : () );
      foreach my $dir (@dirs) {
        if (-d $dir) {
          # Some versions of rmtree will abort if you attempt to remove
          # the directory you are sitting in. We protect that and turn it
          # into a warning. We do this because this occurs during
          # cleanup and so can not be caught by the user.
          eval { rmtree($dir, $DEBUG, 0); };
          warn $@ if ($@ && $^W);
        }
      }

      # clear the arrays
      @{ $files_to_unlink{$$} } = ()
        if exists $files_to_unlink{$$};
      @{ $dirs_to_unlink{$$} } = ()
        if exists $dirs_to_unlink{$$};
    }
  }


  # This is the sub called to register a file for deferred unlinking
  # This could simply store the input parameters and defer everything
  # until the END block. For now we do a bit of checking at this
  # point in order to make sure that (1) we have a file/dir to delete
  # and (2) we have been called with the correct arguments.
  sub _deferred_unlink {

    croak 'Usage:  _deferred_unlink($fh, $fname, $isdir)'
      unless scalar(@_) == 3;

    my ($fh, $fname, $isdir) = @_;

    warn "Setting up deferred removal of $fname\n"
      if $DEBUG;

    # If we have a directory, check that it is a directory
    if ($isdir) {

      if (-d $fname) {

        # Directory exists so store it
        # first on VMS turn []foo into [.foo] for rmtree
        $fname = VMS::Filespec::vmspath($fname) if $^O eq 'VMS';
        $dirs_to_unlink{$$} = [] 
          unless exists $dirs_to_unlink{$$};
        push (@{ $dirs_to_unlink{$$} }, $fname);

      } else {
        carp "Request to remove directory $fname could not be completed since it does not exist!\n" if $^W;
      }

    } else {

      if (-f $fname) {

        # file exists so store handle and name for later removal
        $files_to_unlink{$$} = []
          unless exists $files_to_unlink{$$};
        push(@{ $files_to_unlink{$$} }, [$fh, $fname]);

      } else {
        carp "Request to remove file $fname could not be completed since it is not there!\n" if $^W;
      }

    }

  }


}

#line 1008

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  # read arguments and convert keys to upper case
  my %args = @_;
  %args = map { uc($_), $args{$_} } keys %args;

  # see if they are unlinking (defaulting to yes)
  my $unlink = (exists $args{UNLINK} ? $args{UNLINK} : 1 );
  delete $args{UNLINK};

  # template (store it in an array so that it will
  # disappear from the arg list of tempfile)
  my @template = ( exists $args{TEMPLATE} ? $args{TEMPLATE} : () );
  delete $args{TEMPLATE};

  # Protect OPEN
  delete $args{OPEN};

  # Open the file and retain file handle and file name
  my ($fh, $path) = tempfile( @template, %args );

  print "Tmp: $fh - $path\n" if $DEBUG;

  # Store the filename in the scalar slot
  ${*$fh} = $path;

  # Cache the filename by pid so that the destructor can decide whether to remove it
  $FILES_CREATED_BY_OBJECT{$$}{$path} = 1;

  # Store unlink information in hash slot (plus other constructor info)
  %{*$fh} = %args;

  # create the object
  bless $fh, $class;

  # final method-based configuration
  $fh->unlink_on_destroy( $unlink );

  return $fh;
}

#line 1066

sub newdir {
  my $self = shift;

  # need to handle args as in tempdir because we have to force CLEANUP
  # default without passing CLEANUP to tempdir
  my $template = (scalar(@_) % 2 == 1 ? shift(@_) : undef );
  my %options = @_;
  my $cleanup = (exists $options{CLEANUP} ? $options{CLEANUP} : 1 );

  delete $options{CLEANUP};

  my $tempdir;
  if (defined $template) {
    $tempdir = tempdir( $template, %options );
  } else {
    $tempdir = tempdir( %options );
  }
  return bless { DIRNAME => $tempdir,
                 CLEANUP => $cleanup,
                 LAUNCHPID => $$,
               }, "File::Temp::Dir";
}

#line 1101

sub filename {
  my $self = shift;
  return ${*$self};
}

sub STRINGIFY {
  my $self = shift;
  return $self->filename;
}

#line 1131

sub unlink_on_destroy {
  my $self = shift;
  if (@_) {
    ${*$self}{UNLINK} = shift;
  }
  return ${*$self}{UNLINK};
}

#line 1160

sub DESTROY {
  local($., $@, $!, $^E, $?);
  my $self = shift;

  # Make sure we always remove the file from the global hash
  # on destruction. This prevents the hash from growing uncontrollably
  # and post-destruction there is no reason to know about the file.
  my $file = $self->filename;
  my $was_created_by_proc;
  if (exists $FILES_CREATED_BY_OBJECT{$$}{$file}) {
    $was_created_by_proc = 1;
    delete $FILES_CREATED_BY_OBJECT{$$}{$file};
  }

  if (${*$self}{UNLINK} && !$KEEP_ALL) {
    print "# --------->   Unlinking $self\n" if $DEBUG;

    # only delete if this process created it
    return unless $was_created_by_proc;

    # The unlink1 may fail if the file has been closed
    # by the caller. This leaves us with the decision
    # of whether to refuse to remove the file or simply
    # do an unlink without test. Seems to be silly
    # to do this when we are trying to be careful
    # about security
    _force_writable( $file ); # for windows
    unlink1( $self, $file )
      or unlink($file);
  }
}

#line 1294

sub tempfile {

  # Can not check for argument count since we can have any
  # number of args

  # Default options
  my %options = (
                 "DIR"    => undef, # Directory prefix
                 "SUFFIX" => '',    # Template suffix
                 "UNLINK" => 0,     # Do not unlink file on exit
                 "OPEN"   => 1,     # Open file
                 "TMPDIR" => 0, # Place tempfile in tempdir if template specified
                 "EXLOCK" => 1, # Open file with O_EXLOCK
                );

  # Check to see whether we have an odd or even number of arguments
  my $template = (scalar(@_) % 2 == 1 ? shift(@_) : undef);

  # Read the options and merge with defaults
  %options = (%options, @_)  if @_;

  # First decision is whether or not to open the file
  if (! $options{"OPEN"}) {

    warn "tempfile(): temporary filename requested but not opened.\nPossibly unsafe, consider using tempfile() with OPEN set to true\n"
      if $^W;

  }

  if ($options{"DIR"} and $^O eq 'VMS') {

    # on VMS turn []foo into [.foo] for concatenation
    $options{"DIR"} = VMS::Filespec::vmspath($options{"DIR"});
  }

  # Construct the template

  # Have a choice of trying to work around the mkstemp/mktemp/tmpnam etc
  # functions or simply constructing a template and using _gettemp()
  # explicitly. Go for the latter

  # First generate a template if not defined and prefix the directory
  # If no template must prefix the temp directory
  if (defined $template) {
    # End up with current directory if neither DIR not TMPDIR are set
    if ($options{"DIR"}) {

      $template = File::Spec->catfile($options{"DIR"}, $template);

    } elsif ($options{TMPDIR}) {

      $template = File::Spec->catfile(File::Spec->tmpdir, $template );

    }

  } else {

    if ($options{"DIR"}) {

      $template = File::Spec->catfile($options{"DIR"}, TEMPXXX);

    } else {

      $template = File::Spec->catfile(File::Spec->tmpdir, TEMPXXX);

    }

  }

  # Now add a suffix
  $template .= $options{"SUFFIX"};

  # Determine whether we should tell _gettemp to unlink the file
  # On unix this is irrelevant and can be worked out after the file is
  # opened (simply by unlinking the open filehandle). On Windows or VMS
  # we have to indicate temporary-ness when we open the file. In general
  # we only want a true temporary file if we are returning just the
  # filehandle - if the user wants the filename they probably do not
  # want the file to disappear as soon as they close it (which may be
  # important if they want a child process to use the file)
  # For this reason, tie unlink_on_close to the return context regardless
  # of OS.
  my $unlink_on_close = ( wantarray ? 0 : 1);

  # Create the file
  my ($fh, $path, $errstr);
  croak "Error in tempfile() using $template: $errstr"
    unless (($fh, $path) = _gettemp($template,
                                    "open" => $options{'OPEN'},
                                    "mkdir"=> 0 ,
                                    "unlink_on_close" => $unlink_on_close,
                                    "suffixlen" => length($options{'SUFFIX'}),
                                    "ErrStr" => \$errstr,
                                    "use_exlock" => $options{EXLOCK},
                                   ) );

  # Set up an exit handler that can do whatever is right for the
  # system. This removes files at exit when requested explicitly or when
  # system is asked to unlink_on_close but is unable to do so because
  # of OS limitations.
  # The latter should be achieved by using a tied filehandle.
  # Do not check return status since this is all done with END blocks.
  _deferred_unlink($fh, $path, 0) if $options{"UNLINK"};

  # Return
  if (wantarray()) {

    if ($options{'OPEN'}) {
      return ($fh, $path);
    } else {
      return (undef, $path);
    }

  } else {

    # Unlink the file. It is up to unlink0 to decide what to do with
    # this (whether to unlink now or to defer until later)
    unlink0($fh, $path) or croak "Error unlinking file $path using unlink0";

    # Return just the filehandle.
    return $fh;
  }


}

#line 1483

# '

sub tempdir  {

  # Can not check for argument count since we can have any
  # number of args

  # Default options
  my %options = (
                 "CLEANUP"    => 0, # Remove directory on exit
                 "DIR"        => '', # Root directory
                 "TMPDIR"     => 0,  # Use tempdir with template
                );

  # Check to see whether we have an odd or even number of arguments
  my $template = (scalar(@_) % 2 == 1 ? shift(@_) : undef );

  # Read the options and merge with defaults
  %options = (%options, @_)  if @_;

  # Modify or generate the template

  # Deal with the DIR and TMPDIR options
  if (defined $template) {

    # Need to strip directory path if using DIR or TMPDIR
    if ($options{'TMPDIR'} || $options{'DIR'}) {

      # Strip parent directory from the filename
      #
      # There is no filename at the end
      $template = VMS::Filespec::vmspath($template) if $^O eq 'VMS';
      my ($volume, $directories, undef) = File::Spec->splitpath( $template, 1);

      # Last directory is then our template
      $template = (File::Spec->splitdir($directories))[-1];

      # Prepend the supplied directory or temp dir
      if ($options{"DIR"}) {

        $template = File::Spec->catdir($options{"DIR"}, $template);

      } elsif ($options{TMPDIR}) {

        # Prepend tmpdir
        $template = File::Spec->catdir(File::Spec->tmpdir, $template);

      }

    }

  } else {

    if ($options{"DIR"}) {

      $template = File::Spec->catdir($options{"DIR"}, TEMPXXX);

    } else {

      $template = File::Spec->catdir(File::Spec->tmpdir, TEMPXXX);

    }

  }

  # Create the directory
  my $tempdir;
  my $suffixlen = 0;
  if ($^O eq 'VMS') {           # dir names can end in delimiters
    $template =~ m/([\.\]:>]+)$/;
    $suffixlen = length($1);
  }
  if ( ($^O eq 'MacOS') && (substr($template, -1) eq ':') ) {
    # dir name has a trailing ':'
    ++$suffixlen;
  }

  my $errstr;
  croak "Error in tempdir() using $template: $errstr"
    unless ((undef, $tempdir) = _gettemp($template,
                                         "open" => 0,
                                         "mkdir"=> 1 ,
                                         "suffixlen" => $suffixlen,
                                         "ErrStr" => \$errstr,
                                        ) );

  # Install exit handler; must be dynamic to get lexical
  if ( $options{'CLEANUP'} && -d $tempdir) {
    _deferred_unlink(undef, $tempdir, 1);
  }

  # Return the dir name
  return $tempdir;

}

#line 1605



sub mkstemp {

  croak "Usage: mkstemp(template)"
    if scalar(@_) != 1;

  my $template = shift;

  my ($fh, $path, $errstr);
  croak "Error in mkstemp using $template: $errstr"
    unless (($fh, $path) = _gettemp($template,
                                    "open" => 1,
                                    "mkdir"=> 0 ,
                                    "suffixlen" => 0,
                                    "ErrStr" => \$errstr,
                                   ) );

  if (wantarray()) {
    return ($fh, $path);
  } else {
    return $fh;
  }

}


#line 1648

sub mkstemps {

  croak "Usage: mkstemps(template, suffix)"
    if scalar(@_) != 2;


  my $template = shift;
  my $suffix   = shift;

  $template .= $suffix;

  my ($fh, $path, $errstr);
  croak "Error in mkstemps using $template: $errstr"
    unless (($fh, $path) = _gettemp($template,
                                    "open" => 1,
                                    "mkdir"=> 0 ,
                                    "suffixlen" => length($suffix),
                                    "ErrStr" => \$errstr,
                                   ) );

  if (wantarray()) {
    return ($fh, $path);
  } else {
    return $fh;
  }

}

#line 1691

#' # for emacs

sub mkdtemp {

  croak "Usage: mkdtemp(template)"
    if scalar(@_) != 1;

  my $template = shift;
  my $suffixlen = 0;
  if ($^O eq 'VMS') {           # dir names can end in delimiters
    $template =~ m/([\.\]:>]+)$/;
    $suffixlen = length($1);
  }
  if ( ($^O eq 'MacOS') && (substr($template, -1) eq ':') ) {
    # dir name has a trailing ':'
    ++$suffixlen;
  }
  my ($junk, $tmpdir, $errstr);
  croak "Error creating temp directory from template $template\: $errstr"
    unless (($junk, $tmpdir) = _gettemp($template,
                                        "open" => 0,
                                        "mkdir"=> 1 ,
                                        "suffixlen" => $suffixlen,
                                        "ErrStr" => \$errstr,
                                       ) );

  return $tmpdir;

}

#line 1734

sub mktemp {

  croak "Usage: mktemp(template)"
    if scalar(@_) != 1;

  my $template = shift;

  my ($tmpname, $junk, $errstr);
  croak "Error getting name to temp file from template $template: $errstr"
    unless (($junk, $tmpname) = _gettemp($template,
                                         "open" => 0,
                                         "mkdir"=> 0 ,
                                         "suffixlen" => 0,
                                         "ErrStr" => \$errstr,
                                        ) );

  return $tmpname;
}

#line 1796

sub tmpnam {

  # Retrieve the temporary directory name
  my $tmpdir = File::Spec->tmpdir;

  croak "Error temporary directory is not writable"
    if $tmpdir eq '';

  # Use a ten character template and append to tmpdir
  my $template = File::Spec->catfile($tmpdir, TEMPXXX);

  if (wantarray() ) {
    return mkstemp($template);
  } else {
    return mktemp($template);
  }

}

#line 1832

sub tmpfile {

  # Simply call tmpnam() in a list context
  my ($fh, $file) = tmpnam();

  # Make sure file is removed when filehandle is closed
  # This will fail on NFS
  unlink0($fh, $file)
    or return undef;

  return $fh;

}

#line 1877

sub tempnam {

  croak 'Usage tempnam($dir, $prefix)' unless scalar(@_) == 2;

  my ($dir, $prefix) = @_;

  # Add a string to the prefix
  $prefix .= 'XXXXXXXX';

  # Concatenate the directory to the file
  my $template = File::Spec->catfile($dir, $prefix);

  return mktemp($template);

}

#line 1949

sub unlink0 {

  croak 'Usage: unlink0(filehandle, filename)'
    unless scalar(@_) == 2;

  # Read args
  my ($fh, $path) = @_;

  cmpstat($fh, $path) or return 0;

  # attempt remove the file (does not work on some platforms)
  if (_can_unlink_opened_file()) {

    # return early (Without unlink) if we have been instructed to retain files.
    return 1 if $KEEP_ALL;

    # XXX: do *not* call this on a directory; possible race
    #      resulting in recursive removal
    croak "unlink0: $path has become a directory!" if -d $path;
    unlink($path) or return 0;

    # Stat the filehandle
    my @fh = stat $fh;

    print "Link count = $fh[3] \n" if $DEBUG;

    # Make sure that the link count is zero
    # - Cygwin provides deferred unlinking, however,
    #   on Win9x the link count remains 1
    # On NFS the link count may still be 1 but we cant know that
    # we are on NFS
    return ( $fh[3] == 0 or $^O eq 'cygwin' ? 1 : 0);

  } else {
    _deferred_unlink($fh, $path, 0);
    return 1;
  }

}

#line 2014

sub cmpstat {

  croak 'Usage: cmpstat(filehandle, filename)'
    unless scalar(@_) == 2;

  # Read args
  my ($fh, $path) = @_;

  warn "Comparing stat\n"
    if $DEBUG;

  # Stat the filehandle - which may be closed if someone has manually
  # closed the file. Can not turn off warnings without using $^W
  # unless we upgrade to 5.006 minimum requirement
  my @fh;
  {
    local ($^W) = 0;
    @fh = stat $fh;
  }
  return unless @fh;

  if ($fh[3] > 1 && $^W) {
    carp "unlink0: fstat found too many links; SB=@fh" if $^W;
  }

  # Stat the path
  my @path = stat $path;

  unless (@path) {
    carp "unlink0: $path is gone already" if $^W;
    return;
  }

  # this is no longer a file, but may be a directory, or worse
  unless (-f $path) {
    confess "panic: $path is no longer a file: SB=@fh";
  }

  # Do comparison of each member of the array
  # On WinNT dev and rdev seem to be different
  # depending on whether it is a file or a handle.
  # Cannot simply compare all members of the stat return
  # Select the ones we can use
  my @okstat = (0..$#fh);       # Use all by default
  if ($^O eq 'MSWin32') {
    @okstat = (1,2,3,4,5,7,8,9,10);
  } elsif ($^O eq 'os2') {
    @okstat = (0, 2..$#fh);
  } elsif ($^O eq 'VMS') {      # device and file ID are sufficient
    @okstat = (0, 1);
  } elsif ($^O eq 'dos') {
    @okstat = (0,2..7,11..$#fh);
  } elsif ($^O eq 'mpeix') {
    @okstat = (0..4,8..10);
  }

  # Now compare each entry explicitly by number
  for (@okstat) {
    print "Comparing: $_ : $fh[$_] and $path[$_]\n" if $DEBUG;
    # Use eq rather than == since rdev, blksize, and blocks (6, 11,
    # and 12) will be '' on platforms that do not support them.  This
    # is fine since we are only comparing integers.
    unless ($fh[$_] eq $path[$_]) {
      warn "Did not match $_ element of stat\n" if $DEBUG;
      return 0;
    }
  }

  return 1;
}

#line 2107

sub unlink1 {
  croak 'Usage: unlink1(filehandle, filename)'
    unless scalar(@_) == 2;

  # Read args
  my ($fh, $path) = @_;

  cmpstat($fh, $path) or return 0;

  # Close the file
  close( $fh ) or return 0;

  # Make sure the file is writable (for windows)
  _force_writable( $path );

  # return early (without unlink) if we have been instructed to retain files.
  return 1 if $KEEP_ALL;

  # remove the file
  return unlink($path);
}

#line 2222

{
  # protect from using the variable itself
  my $LEVEL = STANDARD;
  sub safe_level {
    my $self = shift;
    if (@_) {
      my $level = shift;
      if (($level != STANDARD) && ($level != MEDIUM) && ($level != HIGH)) {
        carp "safe_level: Specified level ($level) not STANDARD, MEDIUM or HIGH - ignoring\n" if $^W;
      } else {
        # Dont allow this on perl 5.005 or earlier
        if ($] < 5.006 && $level != STANDARD) {
          # Cant do MEDIUM or HIGH checks
          croak "Currently requires perl 5.006 or newer to do the safe checks";
        }
        # Check that we are allowed to change level
        # Silently ignore if we can not.
        $LEVEL = $level if _can_do_level($level);
      }
    }
    return $LEVEL;
  }
}

#line 2267

{
  my $TopSystemUID = 10;
  $TopSystemUID = 197108 if $^O eq 'interix'; # "Administrator"
  sub top_system_uid {
    my $self = shift;
    if (@_) {
      my $newuid = shift;
      croak "top_system_uid: UIDs should be numeric"
        unless $newuid =~ /^\d+$/s;
      $TopSystemUID = $newuid;
    }
    return $TopSystemUID;
  }
}

#line 2402

package File::Temp::Dir;

use File::Path qw/ rmtree /;
use strict;
use overload '""' => "STRINGIFY", fallback => 1;

# private class specifically to support tempdir objects
# created by File::Temp->newdir

# ostensibly the same method interface as File::Temp but without
# inheriting all the IO::Seekable methods and other cruft

# Read-only - returns the name of the temp directory

sub dirname {
  my $self = shift;
  return $self->{DIRNAME};
}

sub STRINGIFY {
  my $self = shift;
  return $self->dirname;
}

sub unlink_on_destroy {
  my $self = shift;
  if (@_) {
    $self->{CLEANUP} = shift;
  }
  return $self->{CLEANUP};
}

sub DESTROY {
  my $self = shift;
  local($., $@, $!, $^E, $?);
  if ($self->unlink_on_destroy && 
      $$ == $self->{LAUNCHPID} && !$File::Temp::KEEP_ALL) {
    if (-d $self->{DIRNAME}) {
      # Some versions of rmtree will abort if you attempt to remove
      # the directory you are sitting in. We protect that and turn it
      # into a warning. We do this because this occurs during object
      # destruction and so can not be caught by the user.
      eval { rmtree($self->{DIRNAME}, $File::Temp::DEBUG, 0); };
      warn $@ if ($@ && $^W);
    }
  }
}


1;
FILE   9b0085a4/FileHandle.pm  f#line 1 "/usr/share/perl/5.14/FileHandle.pm"
package FileHandle;

use 5.006;
use strict;
our($VERSION, @ISA, @EXPORT, @EXPORT_OK);

$VERSION = "2.02";

require IO::File;
@ISA = qw(IO::File);

@EXPORT = qw(_IOFBF _IOLBF _IONBF);

@EXPORT_OK = qw(
    pipe

    autoflush
    output_field_separator
    output_record_separator
    input_record_separator
    input_line_number
    format_page_number
    format_lines_per_page
    format_lines_left
    format_name
    format_top_name
    format_line_break_characters
    format_formfeed

    print
    printf
    getline
    getlines
);

#
# Everything we're willing to export, we must first import.
#
import IO::Handle grep { !defined(&$_) } @EXPORT, @EXPORT_OK;

#
# Some people call "FileHandle::function", so all the functions
# that were in the old FileHandle class must be imported, too.
#
{
    no strict 'refs';

    my %import = (
	'IO::Handle' =>
	    [qw(DESTROY new_from_fd fdopen close fileno getc ungetc gets
		eof flush error clearerr setbuf setvbuf _open_mode_string)],
	'IO::Seekable' =>
	    [qw(seek tell getpos setpos)],
	'IO::File' =>
	    [qw(new new_tmpfile open)]
    );
    for my $pkg (keys %import) {
	for my $func (@{$import{$pkg}}) {
	    my $c = *{"${pkg}::$func"}{CODE}
		or die "${pkg}::$func missing";
	    *$func = $c;
	}
    }
}

#
# Specialized importer for Fcntl magic.
#
sub import {
    my $pkg = shift;
    my $callpkg = caller;
    require Exporter;
    Exporter::export($pkg, $callpkg, @_);

    #
    # If the Fcntl extension is available,
    #  export its constants.
    #
    eval {
	require Fcntl;
	Exporter::export('Fcntl', $callpkg);
    };
}

################################################
# This is the only exported function we define;
# the rest come from other classes.
#

sub pipe {
    my $r = new IO::Handle;
    my $w = new IO::Handle;
    CORE::pipe($r, $w) or return undef;
    ($r, $w);
}

# Rebless standard file handles
bless *STDIN{IO},  "FileHandle" if ref *STDIN{IO}  eq "IO::Handle";
bless *STDOUT{IO}, "FileHandle" if ref *STDOUT{IO} eq "IO::Handle";
bless *STDERR{IO}, "FileHandle" if ref *STDERR{IO} eq "IO::Handle";

1;

__END__

FILE   '76fc8660/IO/Compress/Adapter/Deflate.pm  ;#line 1 "/usr/share/perl/5.14/IO/Compress/Adapter/Deflate.pm"
package IO::Compress::Adapter::Deflate ;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common  2.033 qw(:Status);

use Compress::Raw::Zlib  2.033 qw(Z_OK Z_FINISH MAX_WBITS) ;
our ($VERSION);

$VERSION = '2.033';

sub mkCompObject
{
    my $crc32    = shift ;
    my $adler32  = shift ;
    my $level    = shift ;
    my $strategy = shift ;

    my ($def, $status) = new Compress::Raw::Zlib::Deflate
                                -AppendOutput   => 1,
                                -CRC32          => $crc32,
                                -ADLER32        => $adler32,
                                -Level          => $level,
                                -Strategy       => $strategy,
                                -WindowBits     => - MAX_WBITS;

    return (undef, "Cannot create Deflate object: $status", $status) 
        if $status != Z_OK;    

    return bless {'Def'        => $def,
                  'Error'      => '',
                 } ;     
}

sub compr
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflate($_[0], $_[1]) ;
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub flush
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $opt = $_[1] || Z_FINISH;
    my $status = $def->flush($_[0], $opt);
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
    
}

sub close
{
    my $self = shift ;

    my $def   = $self->{Def};

    $def->flush($_[0], Z_FINISH)
        if defined $def ;
}

sub reset
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateReset() ;
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub deflateParams 
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateParams(@_);
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "deflateParams Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;   
}



#sub total_out
#{
#    my $self = shift ;
#    $self->{Def}->total_out();
#}
#
#sub total_in
#{
#    my $self = shift ;
#    $self->{Def}->total_in();
#}

sub compressedBytes
{
    my $self = shift ;

    $self->{Def}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Def}->uncompressedBytes();
}




sub crc32
{
    my $self = shift ;
    $self->{Def}->crc32();
}

sub adler32
{
    my $self = shift ;
    $self->{Def}->adler32();
}


1;

__END__

FILE   f4bfb419/IO/Compress/Base.pm  QC#line 1 "/usr/share/perl/5.14/IO/Compress/Base.pm"

package IO::Compress::Base ;

require 5.004 ;

use strict ;
use warnings;

use IO::Compress::Base::Common 2.033 ;

use IO::File ;
use Scalar::Util qw(blessed readonly);

#use File::Glob;
#require Exporter ;
use Carp ;
use Symbol;
use bytes;

our (@ISA, $VERSION);
@ISA    = qw(Exporter IO::File);

$VERSION = '2.033';

#Can't locate object method "SWASHNEW" via package "utf8" (perhaps you forgot to load "utf8"?) at .../ext/Compress-Zlib/Gzip/blib/lib/Compress/Zlib/Common.pm line 16.

sub saveStatus
{
    my $self   = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 ;
    ${ *$self->{Error} } = '' ;

    return ${ *$self->{ErrorNo} } ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;
    ${ *$self->{Error} } = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 if @_ ;

    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    croak $_[0];
}

sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}



sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return ${ *$self->{ErrorNo} } ;
}


sub writeAt
{
    my $self = shift ;
    my $offset = shift;
    my $data = shift;

    if (defined *$self->{FH}) {
        my $here = tell(*$self->{FH});
        return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) 
            if $here < 0 ;
        seek(*$self->{FH}, $offset, SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
        defined *$self->{FH}->write($data, length $data)
            or return $self->saveErrorString(undef, $!, $!) ;
        seek(*$self->{FH}, $here, SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
    }
    else {
        substr(${ *$self->{Buffer} }, $offset, length($data)) = $data ;
    }

    return 1;
}

sub output
{
    my $self = shift ;
    my $data = shift ;
    my $last = shift ;

    return 1 
        if length $data == 0 && ! $last ;

    if ( *$self->{FilterEnvelope} ) {
        *_ = \$data;
        &{ *$self->{FilterEnvelope} }();
    }

    if (length $data) {
        if ( defined *$self->{FH} ) {
                defined *$self->{FH}->write( $data, length $data )
                or return $self->saveErrorString(0, $!, $!); 
        }
        else {
                ${ *$self->{Buffer} } .= $data ;
        }
    }

    return 1;
}

sub getOneShotParams
{
    return ( 'MultiStream' => [1, 1, Parse_boolean,   1],
           );
}

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();

    $got->parse(
        {
            # Generic Parameters
            'AutoClose' => [1, 1, Parse_boolean,   0],
            #'Encode'    => [1, 1, Parse_any,       undef],
            'Strict'    => [0, 1, Parse_boolean,   1],
            'Append'    => [1, 1, Parse_boolean,   0],
            'BinModeIn' => [1, 1, Parse_boolean,   0],

            'FilterEnvelope' => [1, 1, Parse_any,   undef],

            $self->getExtraParams(),
            *$self->{OneShot} ? $self->getOneShotParams() 
                              : (),
        }, 
        @_) or $self->croakError("${class}: $got->{Error}")  ;

    return $got ;
}

sub _create
{
    my $obj = shift;
    my $got = shift;

    *$obj->{Closed} = 1 ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Output parameter")
        if ! @_ && ! $got ;

    my $outValue = shift ;
    my $oneShot = 1 ;

    if (! $got)
    {
        $oneShot = 0 ;
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $lax = ! $got->value('Strict') ;

    my $outType = whatIsOutput($outValue);

    $obj->ckOutputParam($class, $outValue)
        or return undef ;

    if ($outType eq 'buffer') {
        *$obj->{Buffer} = $outValue;
    }
    else {
        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

    # Merge implies Append
    my $merge = $got->value('Merge') ;
    my $appendOutput = $got->value('Append') || $merge ;
    *$obj->{Append} = $appendOutput;
    *$obj->{FilterEnvelope} = $got->value('FilterEnvelope') ;

    if ($merge)
    {
        # Switch off Merge mode if output file/buffer is empty/doesn't exist
        if (($outType eq 'buffer' && length $$outValue == 0 ) ||
            ($outType ne 'buffer' && (! -e $outValue || (-w _ && -z _))) )
          { $merge = 0 }
    }

    # If output is a file, check that it is writable
    #no warnings;
    #if ($outType eq 'filename' && -e $outValue && ! -w _)
    #  { return $obj->saveErrorString(undef, "Output file '$outValue' is not writable" ) }



    if ($got->parsed('Encode')) { 
        my $want_encoding = $got->value('Encode');
        *$obj->{Encoding} = getEncoding($obj, $class, $want_encoding);
    }

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . $obj->error());


    $obj->saveStatus(STATUS_OK) ;

    my $status ;
    if (! $merge)
    {
        *$obj->{Compress} = $obj->mkComp($got)
            or return undef;
        
        *$obj->{UnCompSize} = new U64 ;
        *$obj->{CompSize} = new U64 ;

        if ( $outType eq 'buffer') {
            ${ *$obj->{Buffer} }  = ''
                unless $appendOutput ;
        }
        else {
            if ($outType eq 'handle') {
                *$obj->{FH} = $outValue ;
                setBinModeOutput(*$obj->{FH}) ;
                $outValue->flush() ;
                *$obj->{Handle} = 1 ;
                if ($appendOutput)
                {
                    seek(*$obj->{FH}, 0, SEEK_END)
                        or return $obj->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;

                }
            }
            elsif ($outType eq 'filename') {    
                no warnings;
                my $mode = '>' ;
                $mode = '>>'
                    if $appendOutput;
                *$obj->{FH} = new IO::File "$mode $outValue" 
                    or return $obj->saveErrorString(undef, "cannot open file '$outValue': $!", $!) ;
                *$obj->{StdIO} = ($outValue eq '-'); 
                setBinModeOutput(*$obj->{FH}) ;
            }
        }

        *$obj->{Header} = $obj->mkHeader($got) ;
        $obj->output( *$obj->{Header} )
            or return undef;
    }
    else
    {
        *$obj->{Compress} = $obj->createMerge($outValue, $outType)
            or return undef;
    }

    *$obj->{Closed} = 0 ;
    *$obj->{AutoClose} = $got->value('AutoClose') ;
    *$obj->{Output} = $outValue;
    *$obj->{ClassName} = $class;
    *$obj->{Got} = $got;
    *$obj->{OneShot} = 0 ;

    return $obj ;
}

sub ckOutputParam 
{
    my $self = shift ;
    my $from = shift ;
    my $outType = whatIsOutput($_[0]);

    $self->croakError("$from: output parameter not a filename, filehandle or scalar ref")
        if ! $outType ;

    #$self->croakError("$from: output filename is undef or null string")
        #if $outType eq 'filename' && (! defined $_[0] || $_[0] eq '')  ;

    $self->croakError("$from: output buffer is read-only")
        if $outType eq 'buffer' && readonly(${ $_[0] });
    
    return 1;    
}


sub _def
{
    my $obj = shift ;
    
    my $class= (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;

    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;

    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;

    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k} 
#                unless defined $v ;
#
#            $obj->_singleTarget($x, 1, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }

    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, 1, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames' 
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';
        
        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $inFile, $in, \$out, @_)
                or return undef ;

            push @$output, \$out ;
            #if ($x->{outType} eq 'array')
            #  { push @$output, \$out }
            #else
            #  { $output->{$in} = \$out }
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, 1, $input, $output, @_);

    croak "should not be here" ;
}

sub _singleTarget
{
    my $obj             = shift ;
    my $x               = shift ;
    my $inputIsFilename = shift;
    my $input           = shift;
    
    if ($x->{oneInput})
    {
        $obj->getFileInfo($x->{Got}, $input)
            if isaFilename($input) and $inputIsFilename ;

        my $z = $obj->_create($x->{Got}, @_)
            or return undef ;


        defined $z->_wr2($input, $inputIsFilename) 
            or return $z->closeError(undef) ;

        return $z->close() ;
    }
    else
    {
        my $afterFirst = 0 ;
        my $inputIsFilename = ($x->{inType} ne 'array');
        my $keep = $x->{Got}->clone();

        #for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        for my $element ( @$input)
        {
            my $isFilename = isaFilename($element);

            if ( $afterFirst ++ )
            {
                defined addInterStream($obj, $element, $isFilename)
                    or return $obj->closeError(undef) ;
            }
            else
            {
                $obj->getFileInfo($x->{Got}, $element)
                    if $isFilename;

                $obj->_create($x->{Got}, @_)
                    or return undef ;
            }

            defined $obj->_wr2($element, $isFilename) 
                or return $obj->closeError(undef) ;

            *$obj->{Got} = $keep->clone();
        }
        return $obj->close() ;
    }

}

sub _wr2
{
    my $self = shift ;

    my $source = shift ;
    my $inputIsFilename = shift;

    my $input = $source ;
    if (! $inputIsFilename)
    {
        $input = \$source 
            if ! ref $source;
    }

    if ( ref $input && ref $input eq 'SCALAR' )
    {
        return $self->syswrite($input, @_) ;
    }

    if ( ! ref $input  || isaFilehandle($input))
    {
        my $isFilehandle = isaFilehandle($input) ;

        my $fh = $input ;

        if ( ! $isFilehandle )
        {
            $fh = new IO::File "<$input"
                or return $self->saveErrorString(undef, "cannot open file '$input': $!", $!) ;
        }
        binmode $fh if *$self->{Got}->valueOrDefault('BinModeIn') ;

        my $status ;
        my $buff ;
        my $count = 0 ;
        while ($status = read($fh, $buff, 16 * 1024)) {
            $count += length $buff;
            defined $self->syswrite($buff, @_) 
                or return undef ;
        }

        return $self->saveErrorString(undef, $!, $!) 
            if ! defined $status ;

        if ( (!$isFilehandle || *$self->{AutoClose}) && $input ne '-')
        {    
            $fh->close() 
                or return undef ;
        }

        return $count ;
    }

    croak "Should not be here";
    return undef;
}

sub addInterStream
{
    my $self = shift ;
    my $input = shift ;
    my $inputIsFilename = shift ;

    if (*$self->{Got}->value('MultiStream'))
    {
        $self->getFileInfo(*$self->{Got}, $input)
            #if isaFilename($input) and $inputIsFilename ;
            if isaFilename($input) ;

        # TODO -- newStream needs to allow gzip/zip header to be modified
        return $self->newStream();
    }
    elsif (*$self->{Got}->value('AutoFlush'))
    {
        #return $self->flush(Z_FULL_FLUSH);
    }

    return 1 ;
}

sub getFileInfo
{
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;
}
  
sub UNTIE
{
    my $self = shift ;
}

sub DESTROY
{
    my $self = shift ;
    local ($., $@, $!, $^E, $?);
    
    $self->close() ;

    # TODO - memory leak with 5.8.0 - this isn't called until 
    #        global destruction
    #
    %{ *$self } = () ;
    undef $self ;
}



sub filterUncompressed
{
}

sub syswrite
{
    my $self = shift ;

    my $buffer ;
    if (ref $_[0] ) {
        $self->croakError( *$self->{ClassName} . "::write: not a scalar reference" )
            unless ref $_[0] eq 'SCALAR' ;
        $buffer = $_[0] ;
    }
    else {
        $buffer = \$_[0] ;
    }

    $] >= 5.008 and ( utf8::downgrade($$buffer, 1) 
        or croak "Wide character in " .  *$self->{ClassName} . "::write:");


    if (@_ > 1) {
        my $slen = defined $$buffer ? length($$buffer) : 0;
        my $len = $slen;
        my $offset = 0;
        $len = $_[1] if $_[1] < $len;

        if (@_ > 2) {
            $offset = $_[2] || 0;
            $self->croakError(*$self->{ClassName} . "::write: offset outside string") 
                if $offset > $slen;
            if ($offset < 0) {
                $offset += $slen;
                $self->croakError( *$self->{ClassName} . "::write: offset outside string") if $offset < 0;
            }
            my $rem = $slen - $offset;
            $len = $rem if $rem < $len;
        }

        $buffer = \substr($$buffer, $offset, $len) ;
    }

    return 0 if ! defined $$buffer || length $$buffer == 0 ;

    if (*$self->{Encoding}) {
        $$buffer = *$self->{Encoding}->encode($$buffer);
    }

    $self->filterUncompressed($buffer);

    my $buffer_length = defined $$buffer ? length($$buffer) : 0 ;
    *$self->{UnCompSize}->add($buffer_length) ;

    my $outBuffer='';
    my $status = *$self->{Compress}->compr($buffer, $outBuffer) ;

    return $self->saveErrorString(undef, *$self->{Compress}{Error}, 
                                         *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->output($outBuffer)
        or return undef;

    return $buffer_length;
}

sub print
{
    my $self = shift;

    #if (ref $self) {
    #    $self = *$self{GLOB} ;
    #}

    if (defined $\) {
        if (defined $,) {
            defined $self->syswrite(join($,, @_) . $\);
        } else {
            defined $self->syswrite(join("", @_) . $\);
        }
    } else {
        if (defined $,) {
            defined $self->syswrite(join($,, @_));
        } else {
            defined $self->syswrite(join("", @_));
        }
    }
}

sub printf
{
    my $self = shift;
    my $fmt = shift;
    defined $self->syswrite(sprintf($fmt, @_));
}



sub flush
{
    my $self = shift ;

    my $outBuffer='';
    my $status = *$self->{Compress}->flush($outBuffer, @_) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, 
                                    *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    if ( defined *$self->{FH} ) {
        *$self->{FH}->clearerr();
    }

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->output($outBuffer)
        or return 0;

    if ( defined *$self->{FH} ) {
        defined *$self->{FH}->flush()
            or return $self->saveErrorString(0, $!, $!); 
    }

    return 1;
}

sub newStream
{
    my $self = shift ;
  
    $self->_writeTrailer()
        or return 0 ;

    my $got = $self->checkParams('newStream', *$self->{Got}, @_)
        or return 0 ;    

    $self->ckParams($got)
        or $self->croakError("newStream: $self->{Error}");

    *$self->{Compress} = $self->mkComp($got)
        or return 0;

    *$self->{Header} = $self->mkHeader($got) ;
    $self->output(*$self->{Header} )
        or return 0;
    
    *$self->{UnCompSize}->reset();
    *$self->{CompSize}->reset();

    return 1 ;
}

sub reset
{
    my $self = shift ;
    return *$self->{Compress}->reset() ;
}

sub _writeTrailer
{
    my $self = shift ;

    my $trailer = '';

    my $status = *$self->{Compress}->close($trailer) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $trailer) ;

    $trailer .= $self->mkTrailer();
    defined $trailer
      or return 0;

    return $self->output($trailer);
}

sub _writeFinalTrailer
{
    my $self = shift ;

    return $self->output($self->mkFinalTrailer());
}

sub close
{
    my $self = shift ;

    return 1 if *$self->{Closed} || ! *$self->{Compress} ;
    *$self->{Closed} = 1 ;

    untie *$self 
        if $] >= 5.008 ;

    $self->_writeTrailer()
        or return 0 ;

    $self->_writeFinalTrailer()
        or return 0 ;

    $self->output( "", 1 )
        or return 0;

    if (defined *$self->{FH}) {

        #if (! *$self->{Handle} || *$self->{AutoClose}) {
        if ((! *$self->{Handle} || *$self->{AutoClose}) && ! *$self->{StdIO}) {
            $! = 0 ;
            *$self->{FH}->close()
                or return $self->saveErrorString(0, $!, $!); 
        }
        delete *$self->{FH} ;
        # This delete can set $! in older Perls, so reset the errno
        $! = 0 ;
    }

    return 1;
}


#sub total_in
#sub total_out
#sub msg
#
#sub crc
#{
#    my $self = shift ;
#    return *$self->{Compress}->crc32() ;
#}
#
#sub msg
#{
#    my $self = shift ;
#    return *$self->{Compress}->msg() ;
#}
#
#sub dict_adler
#{
#    my $self = shift ;
#    return *$self->{Compress}->dict_adler() ;
#}
#
#sub get_Level
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Level() ;
#}
#
#sub get_Strategy
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Strategy() ;
#}


sub tell
{
    my $self = shift ;

    return *$self->{UnCompSize}->get32bit() ;
}

sub eof
{
    my $self = shift ;

    return *$self->{Closed} ;
}


sub seek
{
    my $self     = shift ;
    my $position = shift;
    my $whence   = shift ;

    my $here = $self->tell() ;
    my $target = 0 ;

    #use IO::Handle qw(SEEK_SET SEEK_CUR SEEK_END);
    use IO::Handle ;

    if ($whence == IO::Handle::SEEK_SET) {
        $target = $position ;
    }
    elsif ($whence == IO::Handle::SEEK_CUR || $whence == IO::Handle::SEEK_END) {
        $target = $here + $position ;
    }
    else {
        $self->croakError(*$self->{ClassName} . "::seek: unknown value, $whence, for whence parameter");
    }

    # short circuit if seeking to current offset
    return 1 if $target == $here ;    

    # Outlaw any attempt to seek backwards
    $self->croakError(*$self->{ClassName} . "::seek: cannot seek backwards")
        if $target < $here ;

    # Walk the file to the new offset
    my $offset = $target - $here ;

    my $buffer ;
    defined $self->syswrite("\x00" x $offset)
        or return 0;

    return 1 ;
}

sub binmode
{
    1;
#    my $self     = shift ;
#    return defined *$self->{FH} 
#            ? binmode *$self->{FH} 
#            : 1 ;
}

sub fileno
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->fileno() 
            : undef ;
}

sub opened
{
    my $self     = shift ;
    return ! *$self->{Closed} ;
}

sub autoflush
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->autoflush(@_) 
            : undef ;
}

sub input_line_number
{
    return undef ;
}


sub _notAvailable
{
    my $name = shift ;
    return sub { croak "$name Not Available: File opened only for output" ; } ;
}

*read     = _notAvailable('read');
*READ     = _notAvailable('read');
*readline = _notAvailable('readline');
*READLINE = _notAvailable('readline');
*getc     = _notAvailable('getc');
*GETC     = _notAvailable('getc');

*FILENO   = \&fileno;
*PRINT    = \&print;
*PRINTF   = \&printf;
*WRITE    = \&syswrite;
*write    = \&syswrite;
*SEEK     = \&seek; 
*TELL     = \&tell;
*EOF      = \&eof;
*CLOSE    = \&close;
*BINMODE  = \&binmode;

#*sysread  = \&_notAvailable;
#*syswrite = \&_write;

1; 

__END__

#line 982
FILE   #a885ddef/IO/Compress/Base/Common.pm  T�#line 1 "/usr/share/perl/5.14/IO/Compress/Base/Common.pm"
package IO::Compress::Base::Common;

use strict ;
use warnings;
use bytes;

use Carp;
use Scalar::Util qw(blessed readonly);
use File::GlobMapper;

require Exporter;
our ($VERSION, @ISA, @EXPORT, %EXPORT_TAGS, $HAS_ENCODE);
@ISA = qw(Exporter);
$VERSION = '2.033';

@EXPORT = qw( isaFilehandle isaFilename whatIsInput whatIsOutput 
              isaFileGlobString cleanFileGlobString oneTarget
              setBinModeInput setBinModeOutput
              ckInOutParams 
              createSelfTiedObject
              getEncoding

              WANT_CODE
              WANT_EXT
              WANT_UNDEF
              WANT_HASH

              STATUS_OK
              STATUS_ENDSTREAM
              STATUS_EOF
              STATUS_ERROR
          );  

%EXPORT_TAGS = ( Status => [qw( STATUS_OK
                                 STATUS_ENDSTREAM
                                 STATUS_EOF
                                 STATUS_ERROR
                           )]);

                       
use constant STATUS_OK        => 0;
use constant STATUS_ENDSTREAM => 1;
use constant STATUS_EOF       => 2;
use constant STATUS_ERROR     => -1;
          
sub hasEncode()
{
    if (! defined $HAS_ENCODE) {
        eval
        {
            require Encode;
            Encode->import();
        };

        $HAS_ENCODE = $@ ? 0 : 1 ;
    }

    return $HAS_ENCODE;
}

sub getEncoding($$$)
{
    my $obj = shift;
    my $class = shift ;
    my $want_encoding = shift ;

    $obj->croakError("$class: Encode module needed to use -Encode")
        if ! hasEncode();

    my $encoding = Encode::find_encoding($want_encoding);

    $obj->croakError("$class: Encoding '$want_encoding' is not available")
       if ! $encoding;

    return $encoding;
}

our ($needBinmode);
$needBinmode = ($^O eq 'MSWin32' || 
                    ($] >= 5.006 && eval ' ${^UNICODE} || ${^UTF8LOCALE} '))
                    ? 1 : 1 ;

sub setBinModeInput($)
{
    my $handle = shift ;

    binmode $handle 
        if  $needBinmode;
}

sub setBinModeOutput($)
{
    my $handle = shift ;

    binmode $handle 
        if  $needBinmode;
}

sub isaFilehandle($)
{
    use utf8; # Pragma needed to keep Perl 5.6.0 happy
    return (defined $_[0] and 
             (UNIVERSAL::isa($_[0],'GLOB') or 
              UNIVERSAL::isa($_[0],'IO::Handle') or
              UNIVERSAL::isa(\$_[0],'GLOB')) 
          )
}

sub isaFilename($)
{
    return (defined $_[0] and 
           ! ref $_[0]    and 
           UNIVERSAL::isa(\$_[0], 'SCALAR'));
}

sub isaFileGlobString
{
    return defined $_[0] && $_[0] =~ /^<.*>$/;
}

sub cleanFileGlobString
{
    my $string = shift ;

    $string =~ s/^\s*<\s*(.*)\s*>\s*$/$1/;

    return $string;
}

use constant WANT_CODE  => 1 ;
use constant WANT_EXT   => 2 ;
use constant WANT_UNDEF => 4 ;
#use constant WANT_HASH  => 8 ;
use constant WANT_HASH  => 0 ;

sub whatIsInput($;$)
{
    my $got = whatIs(@_);
    
    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        #use IO::File;
        $got = 'handle';
        $_[0] = *STDIN;
        #$_[0] = new IO::File("<-");
    }

    return $got;
}

sub whatIsOutput($;$)
{
    my $got = whatIs(@_);
    
    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        $got = 'handle';
        $_[0] = *STDOUT;
        #$_[0] = new IO::File(">-");
    }
    
    return $got;
}

sub whatIs ($;$)
{
    return 'handle' if isaFilehandle($_[0]);

    my $wantCode = defined $_[1] && $_[1] & WANT_CODE ;
    my $extended = defined $_[1] && $_[1] & WANT_EXT ;
    my $undef    = defined $_[1] && $_[1] & WANT_UNDEF ;
    my $hash     = defined $_[1] && $_[1] & WANT_HASH ;

    return 'undef'  if ! defined $_[0] && $undef ;

    if (ref $_[0]) {
        return ''       if blessed($_[0]); # is an object
        #return ''       if UNIVERSAL::isa($_[0], 'UNIVERSAL'); # is an object
        return 'buffer' if UNIVERSAL::isa($_[0], 'SCALAR');
        return 'array'  if UNIVERSAL::isa($_[0], 'ARRAY')  && $extended ;
        return 'hash'   if UNIVERSAL::isa($_[0], 'HASH')   && $hash ;
        return 'code'   if UNIVERSAL::isa($_[0], 'CODE')   && $wantCode ;
        return '';
    }

    return 'fileglob' if $extended && isaFileGlobString($_[0]);
    return 'filename';
}

sub oneTarget
{
    return $_[0] =~ /^(code|handle|buffer|filename)$/;
}

sub IO::Compress::Base::Validator::new
{
    my $class = shift ;

    my $Class = shift ;
    my $error_ref = shift ;
    my $reportClass = shift ;

    my %data = (Class       => $Class, 
                Error       => $error_ref,
                reportClass => $reportClass, 
               ) ;

    my $obj = bless \%data, $class ;

    local $Carp::CarpLevel = 1;

    my $inType    = $data{inType}    = whatIsInput($_[0], WANT_EXT|WANT_HASH);
    my $outType   = $data{outType}   = whatIsOutput($_[1], WANT_EXT|WANT_HASH);

    my $oneInput  = $data{oneInput}  = oneTarget($inType);
    my $oneOutput = $data{oneOutput} = oneTarget($outType);

    if (! $inType)
    {
        $obj->croakError("$reportClass: illegal input parameter") ;
        #return undef ;
    }    

#    if ($inType eq 'hash')
#    {
#        $obj->{Hash} = 1 ;
#        $obj->{oneInput} = 1 ;
#        return $obj->validateHash($_[0]);
#    }

    if (! $outType)
    {
        $obj->croakError("$reportClass: illegal output parameter") ;
        #return undef ;
    }    


    if ($inType ne 'fileglob' && $outType eq 'fileglob')
    {
        $obj->croakError("Need input fileglob for outout fileglob");
    }    

#    if ($inType ne 'fileglob' && $outType eq 'hash' && $inType ne 'filename' )
#    {
#        $obj->croakError("input must ne filename or fileglob when output is a hash");
#    }    

    if ($inType eq 'fileglob' && $outType eq 'fileglob')
    {
        $data{GlobMap} = 1 ;
        $data{inType} = $data{outType} = 'filename';
        my $mapper = new File::GlobMapper($_[0], $_[1]);
        if ( ! $mapper )
        {
            return $obj->saveErrorString($File::GlobMapper::Error) ;
        }
        $data{Pairs} = $mapper->getFileMap();

        return $obj;
    }
    
    $obj->croakError("$reportClass: input and output $inType are identical")
        if $inType eq $outType && $_[0] eq $_[1] && $_[0] ne '-' ;

    if ($inType eq 'fileglob') # && $outType ne 'fileglob'
    {
        my $glob = cleanFileGlobString($_[0]);
        my @inputs = glob($glob);

        if (@inputs == 0)
        {
            # TODO -- legal or die?
            die "globmap matched zero file -- legal or die???" ;
        }
        elsif (@inputs == 1)
        {
            $obj->validateInputFilenames($inputs[0])
                or return undef;
            $_[0] = $inputs[0]  ;
            $data{inType} = 'filename' ;
            $data{oneInput} = 1;
        }
        else
        {
            $obj->validateInputFilenames(@inputs)
                or return undef;
            $_[0] = [ @inputs ] ;
            $data{inType} = 'filenames' ;
        }
    }
    elsif ($inType eq 'filename')
    {
        $obj->validateInputFilenames($_[0])
            or return undef;
    }
    elsif ($inType eq 'array')
    {
        $data{inType} = 'filenames' ;
        $obj->validateInputArray($_[0])
            or return undef ;
    }

    return $obj->saveErrorString("$reportClass: output buffer is read-only")
        if $outType eq 'buffer' && readonly(${ $_[1] });

    if ($outType eq 'filename' )
    {
        $obj->croakError("$reportClass: output filename is undef or null string")
            if ! defined $_[1] || $_[1] eq ''  ;

        if (-e $_[1])
        {
            if (-d _ )
            {
                return $obj->saveErrorString("output file '$_[1]' is a directory");
            }
        }
    }
    
    return $obj ;
}

sub IO::Compress::Base::Validator::saveErrorString
{
    my $self   = shift ;
    ${ $self->{Error} } = shift ;
    return undef;
    
}

sub IO::Compress::Base::Validator::croakError
{
    my $self   = shift ;
    $self->saveErrorString($_[0]);
    croak $_[0];
}



sub IO::Compress::Base::Validator::validateInputFilenames
{
    my $self = shift ;

    foreach my $filename (@_)
    {
        $self->croakError("$self->{reportClass}: input filename is undef or null string")
            if ! defined $filename || $filename eq ''  ;

        next if $filename eq '-';

        if (! -e $filename )
        {
            return $self->saveErrorString("input file '$filename' does not exist");
        }

        if (-d _ )
        {
            return $self->saveErrorString("input file '$filename' is a directory");
        }

        if (! -r _ )
        {
            return $self->saveErrorString("cannot open file '$filename': $!");
        }
    }

    return 1 ;
}

sub IO::Compress::Base::Validator::validateInputArray
{
    my $self = shift ;

    if ( @{ $_[0] } == 0 )
    {
        return $self->saveErrorString("empty array reference") ;
    }    

    foreach my $element ( @{ $_[0] } )
    {
        my $inType  = whatIsInput($element);
    
        if (! $inType)
        {
            $self->croakError("unknown input parameter") ;
        }    
        elsif($inType eq 'filename')
        {
            $self->validateInputFilenames($element)
                or return undef ;
        }
        else
        {
            $self->croakError("not a filename") ;
        }
    }

    return 1 ;
}

#sub IO::Compress::Base::Validator::validateHash
#{
#    my $self = shift ;
#    my $href = shift ;
#
#    while (my($k, $v) = each %$href)
#    {
#        my $ktype = whatIsInput($k);
#        my $vtype = whatIsOutput($v, WANT_EXT|WANT_UNDEF) ;
#
#        if ($ktype ne 'filename')
#        {
#            return $self->saveErrorString("hash key not filename") ;
#        }    
#
#        my %valid = map { $_ => 1 } qw(filename buffer array undef handle) ;
#        if (! $valid{$vtype})
#        {
#            return $self->saveErrorString("hash value not ok") ;
#        }    
#    }
#
#    return $self ;
#}

sub createSelfTiedObject
{
    my $class = shift || (caller)[0] ;
    my $error_ref = shift ;

    my $obj = bless Symbol::gensym(), ref($class) || $class;
    tie *$obj, $obj if $] >= 5.005;
    *$obj->{Closed} = 1 ;
    $$error_ref = '';
    *$obj->{Error} = $error_ref ;
    my $errno = 0 ;
    *$obj->{ErrorNo} = \$errno ;

    return $obj;
}



#package Parse::Parameters ;
#
#
#require Exporter;
#our ($VERSION, @ISA, @EXPORT);
#$VERSION = '2.000_08';
#@ISA = qw(Exporter);

$EXPORT_TAGS{Parse} = [qw( ParseParameters 
                           Parse_any Parse_unsigned Parse_signed 
                           Parse_boolean Parse_custom Parse_string
                           Parse_multiple Parse_writable_scalar
                         )
                      ];              

push @EXPORT, @{ $EXPORT_TAGS{Parse} } ;

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
use constant Parse_string   => 0x10;
use constant Parse_custom   => 0x12;

#use constant Parse_store_ref        => 0x100 ;
use constant Parse_multiple         => 0x100 ;
use constant Parse_writable         => 0x200 ;
use constant Parse_writable_scalar  => 0x400 | Parse_writable ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
use constant OFF_FIRST_ONLY => 4 ;
use constant OFF_STICKY     => 5 ;



sub ParseParameters
{
    my $level = shift || 0 ; 

    my $sub = (caller($level + 1))[3] ;
    local $Carp::CarpLevel = 1 ;
    
    return $_[1]
        if @_ == 2 && defined $_[1] && UNIVERSAL::isa($_[1], "IO::Compress::Base::Parameters");
    
    my $p = new IO::Compress::Base::Parameters() ;            
    $p->parse(@_)
        or croak "$sub: $p->{Error}" ;

    return $p;
}

#package IO::Compress::Base::Parameters;

use strict;
use warnings;
use Carp;

sub IO::Compress::Base::Parameters::new
{
    my $class = shift ;

    my $obj = { Error => '',
                Got   => {},
              } ;

    #return bless $obj, ref($class) || $class || __PACKAGE__ ;
    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

sub IO::Compress::Base::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;

    $self->{Error} = $error ;
    return $retval;
}
          
#sub getError
#{
#    my $self = shift ;
#    return $self->{Error} ;
#}
          
sub IO::Compress::Base::Parameters::parse
{
    my $self = shift ;

    my $default = shift ;

    my $got = $self->{Got} ;
    my $firstTime = keys %{ $got } == 0 ;
    my $other;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;
    
        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;
 
        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {
        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;
        
        for my $i (0.. $count / 2 - 1) {
            if ($_[2 * $i] eq '__xxx__') {
                $other = $_[2 * $i + 1] ;
            }
            else {
                push @entered, $_[2 * $i] ;
                push @entered, \$_[2 * $i + 1] ;
            }
        }
    }


    while (my ($key, $v) = each %$default)
    {
        croak "need 4 params [@$v]"
            if @$v != 4 ;

        my ($first_only, $sticky, $type, $value) = @$v ;
        my $x ;
        $self->_checkType($key, \$value, $type, 0, \$x) 
            or return undef ;

        $key = lc $key;

        if ($firstTime || ! $sticky) {
            $x = []
                if $type & Parse_multiple;

            $got->{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
        }

        $got->{$key}[OFF_PARSED] = 0 ;
    }

    my %parsed = ();
    
    if ($other) 
    {
        for my $key (keys %$default)  
        {
            my $canonkey = lc $key;
            if ($other->parsed($canonkey))
            {
                my $value = $other->value($canonkey);
#print "SET '$canonkey' to $value [$$value]\n";
                ++ $parsed{$canonkey};
                $got->{$canonkey}[OFF_PARSED]  = 1;
                $got->{$canonkey}[OFF_DEFAULT] = $value;
                $got->{$canonkey}[OFF_FIXED]   = $value;
            }
        }
    }
    
    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;
 
        if ($got->{$canonkey} && ($firstTime ||
                                  ! $got->{$canonkey}[OFF_FIRST_ONLY]  ))
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $parsed = $parsed{$canonkey};
            ++ $parsed{$canonkey};

            return $self->setError("Muliple instances of '$key' found") 
                if $parsed && ($type & Parse_multiple) == 0 ;

            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;

            $value = $$value ;
            if ($type & Parse_multiple) {
                $got->{$canonkey}[OFF_PARSED] = 1;
                push @{ $got->{$canonkey}[OFF_FIXED] }, $s ;
            }
            else {
                $got->{$canonkey} = [1, $type, $value, $s] ;
            }
        }
        else
          { push (@Bad, $key) }
    }
 
    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) $bad") ;
    }

    return 1;
}

sub IO::Compress::Base::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;

    if ($type & Parse_writable_scalar)
    {
        return $self->setError("Parameter '$key' not writable")
            if $validate &&  readonly $$value ;

        if (ref $$value) 
        {
            return $self->setError("Parameter '$key' not a scalar reference")
                if $validate &&  ref $$value ne 'SCALAR' ;

            $$output = $$value ;
        }
        else  
        {
            return $self->setError("Parameter '$key' not a scalar")
                if $validate &&  ref $value ne 'SCALAR' ;

            $$output = $value ;
        }

        return 1;
    }

#    if ($type & Parse_store_ref)
#    {
#        #$value = $$value
#        #    if ref ${ $value } ;
#
#        $$output = $value ;
#        return 1;
#    }

    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {
        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $validate && $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $validate && $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if $validate && defined $value && $value !~ /^\d*$/;
        $$output =  defined $value ? $value != 0 : 0 ;    
        return 1;
    }
    elsif ($type & Parse_string)
    {
        $$output = defined $value ? $value : "" ;    
        return 1;
    }

    $$output = $value ;
    return 1;
}



sub IO::Compress::Base::Parameters::parsed
{
    my $self = shift ;
    my $name = shift ;

    return $self->{Got}{lc $name}[OFF_PARSED] ;
}

sub IO::Compress::Base::Parameters::value
{
    my $self = shift ;
    my $name = shift ;

    if (@_)
    {
        $self->{Got}{lc $name}[OFF_PARSED]  = 1;
        $self->{Got}{lc $name}[OFF_DEFAULT] = $_[0] ;
        $self->{Got}{lc $name}[OFF_FIXED]   = $_[0] ;
    }

    return $self->{Got}{lc $name}[OFF_FIXED] ;
}

sub IO::Compress::Base::Parameters::valueOrDefault
{
    my $self = shift ;
    my $name = shift ;
    my $default = shift ;

    my $value = $self->{Got}{lc $name}[OFF_DEFAULT] ;

    return $value if defined $value ;
    return $default ;
}

sub IO::Compress::Base::Parameters::wantValue
{
    my $self = shift ;
    my $name = shift ;

    return defined $self->{Got}{lc $name}[OFF_DEFAULT] ;

}

sub IO::Compress::Base::Parameters::clone
{
    my $self = shift ;
    my $obj = { };
    my %got ;

    while (my ($k, $v) = each %{ $self->{Got} }) {
        $got{$k} = [ @$v ];
    }

    $obj->{Error} = $self->{Error};
    $obj->{Got} = \%got ;

    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

package U64;

use constant MAX32 => 0xFFFFFFFF ;
use constant HI_1 => MAX32 + 1 ;
use constant LOW   => 0 ;
use constant HIGH  => 1;

sub new
{
    my $class = shift ;

    my $high = 0 ;
    my $low  = 0 ;

    if (@_ == 2) {
        $high = shift ;
        $low  = shift ;
    }
    elsif (@_ == 1) {
        $low  = shift ;
    }

    bless [$low, $high], $class;
}

sub newUnpack_V64
{
    my $string = shift;

    my ($low, $hi) = unpack "V V", $string ;
    bless [ $low, $hi ], "U64";
}

sub newUnpack_V32
{
    my $string = shift;

    my $low = unpack "V", $string ;
    bless [ $low, 0 ], "U64";
}

sub reset
{
    my $self = shift;
    $self->[HIGH] = $self->[LOW] = 0;
}

sub clone
{
    my $self = shift;
    bless [ @$self ], ref $self ;
}

sub getHigh
{
    my $self = shift;
    return $self->[HIGH];
}

sub getLow
{
    my $self = shift;
    return $self->[LOW];
}

sub get32bit
{
    my $self = shift;
    return $self->[LOW];
}

sub get64bit
{
    my $self = shift;
    # Not using << here because the result will still be
    # a 32-bit value on systems where int size is 32-bits
    return $self->[HIGH] * HI_1 + $self->[LOW];
}

sub add
{
    my $self = shift;
    my $value = shift;

    if (ref $value eq 'U64') {
        $self->[HIGH] += $value->[HIGH] ;
        $value = $value->[LOW];
    }
     
    my $available = MAX32 - $self->[LOW] ;

    if ($value > $available) {
       ++ $self->[HIGH] ;
       $self->[LOW] = $value - $available - 1;
    }
    else {
       $self->[LOW] += $value ;
    }

}

sub equal
{
    my $self = shift;
    my $other = shift;

    return $self->[LOW]  == $other->[LOW] &&
           $self->[HIGH] == $other->[HIGH] ;
}

sub is64bit
{
    my $self = shift;
    return $self->[HIGH] > 0 ;
}

sub getPacked_V64
{
    my $self = shift;

    return pack "V V", @$self ;
}

sub getPacked_V32
{
    my $self = shift;

    return pack "V", $self->[LOW] ;
}

sub pack_V64
{
    my $low  = shift;

    return pack "V V", $low, 0;
}


package IO::Compress::Base::Common;

1;
FILE   ad34a023/IO/Compress/Gzip.pm  �#line 1 "/usr/share/perl/5.14/IO/Compress/Gzip.pm"

package IO::Compress::Gzip ;

require 5.004 ;

use strict ;
use warnings;
use bytes;


use IO::Compress::RawDeflate 2.033 ;

use Compress::Raw::Zlib  2.033 ;
use IO::Compress::Base::Common  2.033 qw(:Status :Parse createSelfTiedObject);
use IO::Compress::Gzip::Constants 2.033 ;
use IO::Compress::Zlib::Extra 2.033 ;

BEGIN
{
    if (defined &utf8::downgrade ) 
      { *noUTF8 = \&utf8::downgrade }
    else
      { *noUTF8 = sub {} }  
}

require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $GzipError);

$VERSION = '2.033';
$GzipError = '' ;

@ISA    = qw(Exporter IO::Compress::RawDeflate);
@EXPORT_OK = qw( $GzipError gzip ) ;
%EXPORT_TAGS = %IO::Compress::RawDeflate::DEFLATE_CONSTANTS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

sub new
{
    my $class = shift ;

    my $obj = createSelfTiedObject($class, \$GzipError);

    $obj->_create(undef, @_);
}


sub gzip
{
    my $obj = createSelfTiedObject(undef, \$GzipError);
    return $obj->_def(@_);
}

#sub newHeader
#{
#    my $self = shift ;
#    #return GZIP_MINIMUM_HEADER ;
#    return $self->mkHeader(*$self->{Got});
#}

sub getExtraParams
{
    my $self = shift ;

    return (
            # zlib behaviour
            $self->getZlibParams(),

            # Gzip header fields
            'Minimal'   => [0, 1, Parse_boolean,   0],
            'Comment'   => [0, 1, Parse_any,       undef],
            'Name'      => [0, 1, Parse_any,       undef],
            'Time'      => [0, 1, Parse_any,       undef],
            'TextFlag'  => [0, 1, Parse_boolean,   0],
            'HeaderCRC' => [0, 1, Parse_boolean,   0],
            'OS_Code'   => [0, 1, Parse_unsigned,  $Compress::Raw::Zlib::gzip_os_code],
            'ExtraField'=> [0, 1, Parse_any,       undef],
            'ExtraFlags'=> [0, 1, Parse_any,       undef],

        );
}


sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gzip always needs crc32
    $got->value('CRC32' => 1);

    return 1
        if $got->value('Merge') ;

    my $strict = $got->value('Strict') ;


    {
        if (! $got->parsed('Time') ) {
            # Modification time defaults to now.
            $got->value('Time' => time) ;
        }

        # Check that the Name & Comment don't have embedded NULLs
        # Also check that they only contain ISO 8859-1 chars.
        if ($got->parsed('Name') && defined $got->value('Name')) {
            my $name = $got->value('Name');
                
            return $self->saveErrorString(undef, "Null Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
        }

        if ($got->parsed('Comment') && defined $got->value('Comment')) {
            my $comment = $got->value('Comment');

            return $self->saveErrorString(undef, "Null Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o;
        }

        if ($got->parsed('OS_Code') ) {
            my $value = $got->value('OS_Code');

            return $self->saveErrorString(undef, "OS_Code must be between 0 and 255, got '$value'")
                if $value < 0 || $value > 255 ;
            
        }

        # gzip only supports Deflate at present
        $got->value('Method' => Z_DEFLATED) ;

        if ( ! $got->parsed('ExtraFlags')) {
            $got->value('ExtraFlags' => 2) 
                if $got->value('Level') == Z_BEST_COMPRESSION ;
            $got->value('ExtraFlags' => 4) 
                if $got->value('Level') == Z_BEST_SPEED ;
        }

        my $data = $got->value('ExtraField') ;
        if (defined $data) {
            my $bad = IO::Compress::Zlib::Extra::parseExtraField($data, $strict, 1) ;
            return $self->saveErrorString(undef, "Error with ExtraField Parameter: $bad", Z_DATA_ERROR)
                if $bad ;

            $got->value('ExtraField', $data) ;
        }
    }

    return 1;
}

sub mkTrailer
{
    my $self = shift ;
    return pack("V V", *$self->{Compress}->crc32(), 
                       *$self->{UnCompSize}->get32bit());
}

sub getInverseClass
{
    return ('IO::Uncompress::Gunzip',
                \$IO::Uncompress::Gunzip::GunzipError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $filename = shift ;

    my $defaultTime = (stat($filename))[9] ;

    $params->value('Name' => $filename)
        if ! $params->parsed('Name') ;

    $params->value('Time' => $defaultTime) 
        if ! $params->parsed('Time') ;
}


sub mkHeader
{
    my $self = shift ;
    my $param = shift ;

    # stort-circuit if a minimal header is requested.
    return GZIP_MINIMUM_HEADER if $param->value('Minimal') ;

    # METHOD
    my $method = $param->valueOrDefault('Method', GZIP_CM_DEFLATED) ;

    # FLAGS
    my $flags       = GZIP_FLG_DEFAULT ;
    $flags |= GZIP_FLG_FTEXT    if $param->value('TextFlag') ;
    $flags |= GZIP_FLG_FHCRC    if $param->value('HeaderCRC') ;
    $flags |= GZIP_FLG_FEXTRA   if $param->wantValue('ExtraField') ;
    $flags |= GZIP_FLG_FNAME    if $param->wantValue('Name') ;
    $flags |= GZIP_FLG_FCOMMENT if $param->wantValue('Comment') ;
    
    # MTIME
    my $time = $param->valueOrDefault('Time', GZIP_MTIME_DEFAULT) ;

    # EXTRA FLAGS
    my $extra_flags = $param->valueOrDefault('ExtraFlags', GZIP_XFL_DEFAULT);

    # OS CODE
    my $os_code = $param->valueOrDefault('OS_Code', GZIP_OS_DEFAULT) ;


    my $out = pack("C4 V C C", 
            GZIP_ID1,   # ID1
            GZIP_ID2,   # ID2
            $method,    # Compression Method
            $flags,     # Flags
            $time,      # Modification Time
            $extra_flags, # Extra Flags
            $os_code,   # Operating System Code
            ) ;

    # EXTRA
    if ($flags & GZIP_FLG_FEXTRA) {
        my $extra = $param->value('ExtraField') ;
        $out .= pack("v", length $extra) . $extra ;
    }

    # NAME
    if ($flags & GZIP_FLG_FNAME) {
        my $name .= $param->value('Name') ;
        $name =~ s/\x00.*$//;
        $out .= $name ;
        # Terminate the filename with NULL unless it already is
        $out .= GZIP_NULL_BYTE 
            if !length $name or
               substr($name, 1, -1) ne GZIP_NULL_BYTE ;
    }

    # COMMENT
    if ($flags & GZIP_FLG_FCOMMENT) {
        my $comment .= $param->value('Comment') ;
        $comment =~ s/\x00.*$//;
        $out .= $comment ;
        # Terminate the comment with NULL unless it already is
        $out .= GZIP_NULL_BYTE
            if ! length $comment or
               substr($comment, 1, -1) ne GZIP_NULL_BYTE;
    }

    # HEADER CRC
    $out .= pack("v", crc32($out) & 0x00FF ) if $param->value('HeaderCRC') ;

    noUTF8($out);

    return $out ;
}

sub mkFinalTrailer
{
    return '';
}

1; 

__END__

#line 1243
FILE   &a7d91066/IO/Compress/Gzip/Constants.pm  |#line 1 "/usr/share/perl/5.14/IO/Compress/Gzip/Constants.pm"
package IO::Compress::Gzip::Constants;

use strict ;
use warnings;
use bytes;

require Exporter;

our ($VERSION, @ISA, @EXPORT, %GZIP_OS_Names);
our ($GZIP_FNAME_INVALID_CHAR_RE, $GZIP_FCOMMENT_INVALID_CHAR_RE);

$VERSION = '2.033';

@ISA = qw(Exporter);

@EXPORT= qw(

    GZIP_ID_SIZE
    GZIP_ID1
    GZIP_ID2

    GZIP_FLG_DEFAULT
    GZIP_FLG_FTEXT
    GZIP_FLG_FHCRC
    GZIP_FLG_FEXTRA
    GZIP_FLG_FNAME
    GZIP_FLG_FCOMMENT
    GZIP_FLG_RESERVED

    GZIP_CM_DEFLATED

    GZIP_MIN_HEADER_SIZE
    GZIP_TRAILER_SIZE

    GZIP_MTIME_DEFAULT
    GZIP_XFL_DEFAULT
    GZIP_FEXTRA_HEADER_SIZE
    GZIP_FEXTRA_MAX_SIZE
    GZIP_FEXTRA_SUBFIELD_HEADER_SIZE
    GZIP_FEXTRA_SUBFIELD_ID_SIZE
    GZIP_FEXTRA_SUBFIELD_LEN_SIZE
    GZIP_FEXTRA_SUBFIELD_MAX_SIZE

    $GZIP_FNAME_INVALID_CHAR_RE
    $GZIP_FCOMMENT_INVALID_CHAR_RE

    GZIP_FHCRC_SIZE

    GZIP_ISIZE_MAX
    GZIP_ISIZE_MOD_VALUE


    GZIP_NULL_BYTE

    GZIP_OS_DEFAULT

    %GZIP_OS_Names

    GZIP_MINIMUM_HEADER

    );

# Constant names derived from RFC 1952

use constant GZIP_ID_SIZE                     => 2 ;
use constant GZIP_ID1                         => 0x1F;
use constant GZIP_ID2                         => 0x8B;

use constant GZIP_MIN_HEADER_SIZE             => 10 ;# minimum gzip header size
use constant GZIP_TRAILER_SIZE                => 8 ;


use constant GZIP_FLG_DEFAULT                 => 0x00 ;
use constant GZIP_FLG_FTEXT                   => 0x01 ;
use constant GZIP_FLG_FHCRC                   => 0x02 ; # called CONTINUATION in gzip
use constant GZIP_FLG_FEXTRA                  => 0x04 ;
use constant GZIP_FLG_FNAME                   => 0x08 ;
use constant GZIP_FLG_FCOMMENT                => 0x10 ;
#use constant GZIP_FLG_ENCRYPTED              => 0x20 ; # documented in gzip sources
use constant GZIP_FLG_RESERVED                => (0x20 | 0x40 | 0x80) ;

use constant GZIP_XFL_DEFAULT                 => 0x00 ;

use constant GZIP_MTIME_DEFAULT               => 0x00 ;

use constant GZIP_FEXTRA_HEADER_SIZE          => 2 ;
use constant GZIP_FEXTRA_MAX_SIZE             => 0xFFFF ;
use constant GZIP_FEXTRA_SUBFIELD_ID_SIZE     => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_LEN_SIZE    => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_HEADER_SIZE => GZIP_FEXTRA_SUBFIELD_ID_SIZE +
                                                 GZIP_FEXTRA_SUBFIELD_LEN_SIZE;
use constant GZIP_FEXTRA_SUBFIELD_MAX_SIZE    => GZIP_FEXTRA_MAX_SIZE - 
                                                 GZIP_FEXTRA_SUBFIELD_HEADER_SIZE ;


if (ord('A') == 193)
{
    # EBCDIC 
    $GZIP_FNAME_INVALID_CHAR_RE = '[\x00-\x3f\xff]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE = '[\x00-\x0a\x11-\x14\x16-\x3f\xff]';
    
}
else
{
    $GZIP_FNAME_INVALID_CHAR_RE       =  '[\x00-\x1F\x7F-\x9F]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE    =  '[\x00-\x09\x11-\x1F\x7F-\x9F]';
}            

use constant GZIP_FHCRC_SIZE        => 2 ; # aka CONTINUATION in gzip

use constant GZIP_CM_DEFLATED       => 8 ;

use constant GZIP_NULL_BYTE         => "\x00";
use constant GZIP_ISIZE_MAX         => 0xFFFFFFFF ;
use constant GZIP_ISIZE_MOD_VALUE   => GZIP_ISIZE_MAX + 1 ;

# OS Names sourced from http://www.gzip.org/format.txt

use constant GZIP_OS_DEFAULT=> 0xFF ;
%GZIP_OS_Names = (
    0   => 'MS-DOS',
    1   => 'Amiga',
    2   => 'VMS',
    3   => 'Unix',
    4   => 'VM/CMS',
    5   => 'Atari TOS',
    6   => 'HPFS (OS/2, NT)',
    7   => 'Macintosh',
    8   => 'Z-System',
    9   => 'CP/M',
    10  => 'TOPS-20',
    11  => 'NTFS (NT)',
    12  => 'SMS QDOS',
    13  => 'Acorn RISCOS',
    14  => 'VFAT file system (Win95, NT)',
    15  => 'MVS',
    16  => 'BeOS',
    17  => 'Tandem/NSK',
    18  => 'THEOS',
    GZIP_OS_DEFAULT()   => 'Unknown',
    ) ;

use constant GZIP_MINIMUM_HEADER =>   pack("C4 V C C",  
        GZIP_ID1, GZIP_ID2, GZIP_CM_DEFLATED, GZIP_FLG_DEFAULT,
        GZIP_MTIME_DEFAULT, GZIP_XFL_DEFAULT, GZIP_OS_DEFAULT) ;


1;
FILE   "0c755159/IO/Compress/RawDeflate.pm  r#line 1 "/usr/share/perl/5.14/IO/Compress/RawDeflate.pm"
package IO::Compress::RawDeflate ;

# create RFC1951
#
use strict ;
use warnings;
use bytes;


use IO::Compress::Base 2.033 ;
use IO::Compress::Base::Common  2.033 qw(:Status createSelfTiedObject);
use IO::Compress::Adapter::Deflate  2.033 ;

require Exporter ;


our ($VERSION, @ISA, @EXPORT_OK, %DEFLATE_CONSTANTS, %EXPORT_TAGS, $RawDeflateError);

$VERSION = '2.033';
$RawDeflateError = '';

@ISA = qw(Exporter IO::Compress::Base);
@EXPORT_OK = qw( $RawDeflateError rawdeflate ) ;

%EXPORT_TAGS = ( flush     => [qw{  
                                    Z_NO_FLUSH
                                    Z_PARTIAL_FLUSH
                                    Z_SYNC_FLUSH
                                    Z_FULL_FLUSH
                                    Z_FINISH
                                    Z_BLOCK
                              }],
                 level     => [qw{  
                                    Z_NO_COMPRESSION
                                    Z_BEST_SPEED
                                    Z_BEST_COMPRESSION
                                    Z_DEFAULT_COMPRESSION
                              }],
                 strategy  => [qw{  
                                    Z_FILTERED
                                    Z_HUFFMAN_ONLY
                                    Z_RLE
                                    Z_FIXED
                                    Z_DEFAULT_STRATEGY
                              }],

              );

{
    my %seen;
    foreach (keys %EXPORT_TAGS )
    {
        push @{$EXPORT_TAGS{constants}}, 
                 grep { !$seen{$_}++ } 
                 @{ $EXPORT_TAGS{$_} }
    }
    $EXPORT_TAGS{all} = $EXPORT_TAGS{constants} ;
}


%DEFLATE_CONSTANTS = %EXPORT_TAGS;

push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;

Exporter::export_ok_tags('all');
              


sub new
{
    my $class = shift ;

    my $obj = createSelfTiedObject($class, \$RawDeflateError);

    return $obj->_create(undef, @_);
}

sub rawdeflate
{
    my $obj = createSelfTiedObject(undef, \$RawDeflateError);
    return $obj->_def(@_);
}

sub ckParams
{
    my $self = shift ;
    my $got = shift;

    return 1 ;
}

sub mkComp
{
    my $self = shift ;
    my $got = shift ;

    my ($obj, $errstr, $errno) = IO::Compress::Adapter::Deflate::mkCompObject(
                                                 $got->value('CRC32'),
                                                 $got->value('Adler32'),
                                                 $got->value('Level'),
                                                 $got->value('Strategy')
                                                 );

   return $self->saveErrorString(undef, $errstr, $errno)
       if ! defined $obj;

   return $obj;    
}


sub mkHeader
{
    my $self = shift ;
    return '';
}

sub mkTrailer
{
    my $self = shift ;
    return '';
}

sub mkFinalTrailer
{
    return '';
}


#sub newHeader
#{
#    my $self = shift ;
#    return '';
#}

sub getExtraParams
{
    my $self = shift ;
    return $self->getZlibParams();
}

sub getZlibParams
{
    my $self = shift ;

    use IO::Compress::Base::Common  2.033 qw(:Parse);
    use Compress::Raw::Zlib  2.033 qw(Z_DEFLATED Z_DEFAULT_COMPRESSION Z_DEFAULT_STRATEGY);

    
    return (
        
            # zlib behaviour
            #'Method'   => [0, 1, Parse_unsigned,  Z_DEFLATED],
            'Level'     => [0, 1, Parse_signed,    Z_DEFAULT_COMPRESSION],
            'Strategy'  => [0, 1, Parse_signed,    Z_DEFAULT_STRATEGY],

            'CRC32'     => [0, 1, Parse_boolean,   0],
            'ADLER32'   => [0, 1, Parse_boolean,   0],
            'Merge'     => [1, 1, Parse_boolean,   0],
        );
    
    
}

sub getInverseClass
{
    return ('IO::Uncompress::RawInflate', 
                \$IO::Uncompress::RawInflate::RawInflateError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $file = shift ;
    
}

use IO::Seekable qw(SEEK_SET);

sub createMerge
{
    my $self = shift ;
    my $outValue = shift ;
    my $outType = shift ;

    my ($invClass, $error_ref) = $self->getInverseClass();
    eval "require $invClass" 
        or die "aaaahhhh" ;

    my $inf = $invClass->new( $outValue, 
                             Transparent => 0, 
                             #Strict     => 1,
                             AutoClose   => 0,
                             Scan        => 1)
       or return $self->saveErrorString(undef, "Cannot create InflateScan object: $$error_ref" ) ;

    my $end_offset = 0;
    $inf->scan() 
        or return $self->saveErrorString(undef, "Error Scanning: $$error_ref", $inf->errorNo) ;
    $inf->zap($end_offset) 
        or return $self->saveErrorString(undef, "Error Zapping: $$error_ref", $inf->errorNo) ;

    my $def = *$self->{Compress} = $inf->createDeflate();

    *$self->{Header} = *$inf->{Info}{Header};
    *$self->{UnCompSize} = *$inf->{UnCompSize}->clone();
    *$self->{CompSize} = *$inf->{CompSize}->clone();
    # TODO -- fix this
    #*$self->{CompSize} = new U64(0, *$self->{UnCompSize_32bit});


    if ( $outType eq 'buffer') 
      { substr( ${ *$self->{Buffer} }, $end_offset) = '' }
    elsif ($outType eq 'handle' || $outType eq 'filename') {
        *$self->{FH} = *$inf->{FH} ;
        delete *$inf->{FH};
        *$self->{FH}->flush() ;
        *$self->{Handle} = 1 if $outType eq 'handle';

        #seek(*$self->{FH}, $end_offset, SEEK_SET) 
        *$self->{FH}->seek($end_offset, SEEK_SET) 
            or return $self->saveErrorString(undef, $!, $!) ;
    }

    return $def ;
}

#### zlib specific methods

sub deflateParams 
{
    my $self = shift ;

    my $level = shift ;
    my $strategy = shift ;

    my $status = *$self->{Compress}->deflateParams(Level => $level, Strategy => $strategy) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    return 1;    
}




1;

__END__

#line 1018
FILE   "11c27802/IO/Compress/Zlib/Extra.pm  �#line 1 "/usr/share/perl/5.14/IO/Compress/Zlib/Extra.pm"
package IO::Compress::Zlib::Extra;

require 5.004 ;

use strict ;
use warnings;
use bytes;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = '2.033';

use IO::Compress::Gzip::Constants 2.033 ;

sub ExtraFieldError
{
    return $_[0];
    return "Error with ExtraField Parameter: $_[0]" ;
}

sub validateExtraFieldPair
{
    my $pair = shift ;
    my $strict = shift;
    my $gzipMode = shift ;

    return ExtraFieldError("Not an array ref")
        unless ref $pair &&  ref $pair eq 'ARRAY';

    return ExtraFieldError("SubField must have two parts")
        unless @$pair == 2 ;

    return ExtraFieldError("SubField ID is a reference")
        if ref $pair->[0] ;

    return ExtraFieldError("SubField Data is a reference")
        if ref $pair->[1] ;

    # ID is exactly two chars   
    return ExtraFieldError("SubField ID not two chars long")
        unless length $pair->[0] == GZIP_FEXTRA_SUBFIELD_ID_SIZE ;

    # Check that the 2nd byte of the ID isn't 0    
    return ExtraFieldError("SubField ID 2nd byte is 0x00")
        if $strict && $gzipMode && substr($pair->[0], 1, 1) eq "\x00" ;

    return ExtraFieldError("SubField Data too long")
        if length $pair->[1] > GZIP_FEXTRA_SUBFIELD_MAX_SIZE ;


    return undef ;
}

sub parseRawExtra
{
    my $data     = shift ;
    my $extraRef = shift;
    my $strict   = shift;
    my $gzipMode = shift ;

    #my $lax = shift ;

    #return undef
    #    if $lax ;

    my $XLEN = length $data ;

    return ExtraFieldError("Too Large")
        if $XLEN > GZIP_FEXTRA_MAX_SIZE;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + GZIP_FEXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, GZIP_FEXTRA_SUBFIELD_ID_SIZE);    
        $offset += GZIP_FEXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            GZIP_FEXTRA_SUBFIELD_LEN_SIZE));
        $offset += GZIP_FEXTRA_SUBFIELD_LEN_SIZE ;

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + $subLen > $XLEN ;

        my $bad = validateExtraFieldPair( [$id, 
                                           substr($data, $offset, $subLen)], 
                                           $strict, $gzipMode );
        return $bad if $bad ;
        push @$extraRef, [$id => substr($data, $offset, $subLen)]
            if defined $extraRef;;

        $offset += $subLen ;
    }

        
    return undef ;
}


sub mkSubField
{
    my $id = shift ;
    my $data = shift ;

    return $id . pack("v", length $data) . $data ;
}

sub parseExtraField
{
    my $dataRef  = $_[0];
    my $strict   = $_[1];
    my $gzipMode = $_[2];
    #my $lax     = @_ == 2 ? $_[1] : 1;


    # ExtraField can be any of
    #
    #    -ExtraField => $data
    #
    #    -ExtraField => [$id1, $data1,
    #                    $id2, $data2]
    #                     ...
    #                   ]
    #
    #    -ExtraField => [ [$id1 => $data1],
    #                     [$id2 => $data2],
    #                     ...
    #                   ]
    #
    #    -ExtraField => { $id1 => $data1,
    #                     $id2 => $data2,
    #                     ...
    #                   }
    
    if ( ! ref $dataRef ) {

        return undef
            if ! $strict;

        return parseRawExtra($dataRef, undef, 1, $gzipMode);
    }

    #my $data = $$dataRef;
    my $data = $dataRef;
    my $out = '' ;

    if (ref $data eq 'ARRAY') {    
        if (ref $data->[0]) {

            foreach my $pair (@$data) {
                return ExtraFieldError("Not list of lists")
                    unless ref $pair eq 'ARRAY' ;

                my $bad = validateExtraFieldPair($pair, $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField(@$pair);
            }   
        }   
        else {
            return ExtraFieldError("Not even number of elements")
                unless @$data % 2  == 0;

            for (my $ix = 0; $ix <= length(@$data) -1 ; $ix += 2) {
                my $bad = validateExtraFieldPair([$data->[$ix],
                                                  $data->[$ix+1]], 
                                                 $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField($data->[$ix], $data->[$ix+1]);
            }   
        }
    }   
    elsif (ref $data eq 'HASH') {    
        while (my ($id, $info) = each %$data) {
            my $bad = validateExtraFieldPair([$id, $info], $strict, $gzipMode);
            return $bad if $bad ;

            $out .= mkSubField($id, $info);
        }   
    }   
    else {
        return ExtraFieldError("Not a scalar, array ref or hash ref") ;
    }

    return ExtraFieldError("Too Large")
        if length $out > GZIP_FEXTRA_MAX_SIZE;

    $_[0] = $out ;

    return undef;
}

1;

__END__
FILE   )2e176626/IO/Uncompress/Adapter/Inflate.pm  
package IO::Uncompress::Adapter::Inflate;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common  2.033 qw(:Status);
use Compress::Raw::Zlib  2.033 qw(Z_OK Z_BUF_ERROR Z_STREAM_END Z_FINISH MAX_WBITS);

our ($VERSION);
$VERSION = '2.033';



sub mkUncompObject
{
    my $crc32   = shift || 1;
    my $adler32 = shift || 1;
    my $scan    = shift || 0;

    my $inflate ;
    my $status ;

    if ($scan)
    {
        ($inflate, $status) = new Compress::Raw::Zlib::InflateScan
                                    #LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }
    else
    {
        ($inflate, $status) = new Compress::Raw::Zlib::Inflate
                                    AppendOutput => 1,
                                    LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }

    return (undef, "Could not create Inflation object: $status", $status) 
        if $status != Z_OK ;

    return bless {'Inf'        => $inflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                  'ConsumesInput' => 1,
                 } ;     
    
}

sub uncompr
{
    my $self = shift ;
    my $from = shift ;
    my $to   = shift ;
    my $eof  = shift ;

    my $inf   = $self->{Inf};

    my $status = $inf->inflate($from, $to, $eof);
    $self->{ErrorNo} = $status;

    if ($status != Z_OK && $status != Z_STREAM_END && $status != Z_BUF_ERROR)
    {
        $self->{Error} = "Inflation Error: $status";
        return STATUS_ERROR;
    }
            
    return STATUS_OK        if $status == Z_BUF_ERROR ; # ???
    return STATUS_OK        if $status == Z_OK ;
    return STATUS_ENDSTREAM if $status == Z_STREAM_END ;
    return STATUS_ERROR ;
}

sub reset
{
    my $self = shift ;
    $self->{Inf}->inflateReset();

    return STATUS_OK ;
}

#sub count
#{
#    my $self = shift ;
#    $self->{Inf}->inflateCount();
#}

sub crc32
{
    my $self = shift ;
    $self->{Inf}->crc32();
}

sub compressedBytes
{
    my $self = shift ;
    $self->{Inf}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Inf}->uncompressedBytes();
}

sub adler32
{
    my $self = shift ;
    $self->{Inf}->adler32();
}

sub sync
{
    my $self = shift ;
    ( $self->{Inf}->inflateSync(@_) == Z_OK) 
            ? STATUS_OK 
            : STATUS_ERROR ;
}


sub getLastBlockOffset
{
    my $self = shift ;
    $self->{Inf}->getLastBlockOffset();
}

sub getEndOffset
{
    my $self = shift ;
    $self->{Inf}->getEndOffset();
}

sub resetLastBlockByte
{
    my $self = shift ;
    $self->{Inf}->resetLastBlockByte(@_);
}

sub createDeflateStream
{
    my $self = shift ;
    my $deflate = $self->{Inf}->createDeflateStream(@_);
    return bless {'Def'        => $deflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                 }, 'IO::Compress::Adapter::Deflate';
}

1;


__END__

FILE   0e4c6a74/IO/Uncompress/Base.pm  �(#line 1 "/usr/share/perl/5.14/IO/Uncompress/Base.pm"

package IO::Uncompress::Base ;

use strict ;
use warnings;
use bytes;

our (@ISA, $VERSION, @EXPORT_OK, %EXPORT_TAGS);
@ISA    = qw(Exporter IO::File);


$VERSION = '2.033';

use constant G_EOF => 0 ;
use constant G_ERR => -1 ;

use IO::Compress::Base::Common 2.033 ;
#use Parse::Parameters ;

use IO::File ;
use Symbol;
use Scalar::Util qw(readonly);
use List::Util qw(min);
use Carp ;

%EXPORT_TAGS = ( );
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
#Exporter::export_ok_tags('all') ;



sub smartRead
{
    my $self = $_[0];
    my $out = $_[1];
    my $size = $_[2];
    #$$out = "" ;
    $$out = "" ;

    my $offset = 0 ;
    my $status = 1;


    if (defined *$self->{InputLength}) {
        return 0
            if *$self->{InputLengthRemaining} <= 0 ;
        $size = min($size, *$self->{InputLengthRemaining});
    }

    if ( length *$self->{Prime} ) {
        #$$out = substr(*$self->{Prime}, 0, $size, '') ;
        $$out = substr(*$self->{Prime}, 0, $size) ;
        substr(*$self->{Prime}, 0, $size) =  '' ;
        if (length $$out == $size) {
            *$self->{InputLengthRemaining} -= length $$out
                if defined *$self->{InputLength};

            return length $$out ;
        }
        $offset = length $$out ;
    }

    my $get_size = $size - $offset ;

    if (defined *$self->{FH}) {
        if ($offset) {
            # Not using this 
            #
            #  *$self->{FH}->read($$out, $get_size, $offset);
            #
            # because the filehandle may not support the offset parameter
            # An example is Net::FTP
            my $tmp = '';
            $status = *$self->{FH}->read($tmp, $get_size) ;
            substr($$out, $offset) = $tmp
                if defined $status && $status > 0 ;
        }
        else
          { $status = *$self->{FH}->read($$out, $get_size) }
    }
    elsif (defined *$self->{InputEvent}) {
        my $got = 1 ;
        while (length $$out < $size) {
            last 
                if ($got = *$self->{InputEvent}->($$out, $get_size)) <= 0;
        }

        if (length $$out > $size ) {
            #*$self->{Prime} = substr($$out, $size, length($$out), '');
            *$self->{Prime} = substr($$out, $size, length($$out));
            substr($$out, $size, length($$out)) =  '';
        }

       *$self->{EventEof} = 1 if $got <= 0 ;
    }
    else {
       no warnings 'uninitialized';
       my $buf = *$self->{Buffer} ;
       $$buf = '' unless defined $$buf ;
       #$$out = '' unless defined $$out ;
       substr($$out, $offset) = substr($$buf, *$self->{BufferOffset}, $get_size);
       if (*$self->{ConsumeInput})
         { substr($$buf, 0, $get_size) = '' }
       else  
         { *$self->{BufferOffset} += length($$out) - $offset }
    }

    *$self->{InputLengthRemaining} -= length($$out) #- $offset 
        if defined *$self->{InputLength};
        
    if (! defined $status) {
        $self->saveStatus($!) ;
        return STATUS_ERROR;
    }

    $self->saveStatus(length $$out < 0 ? STATUS_ERROR : STATUS_OK) ;

    return length $$out;
}

sub pushBack
{
    my $self = shift ;

    return if ! defined $_[0] || length $_[0] == 0 ;

    if (defined *$self->{FH} || defined *$self->{InputEvent} ) {
        *$self->{Prime} = $_[0] . *$self->{Prime} ;
        *$self->{InputLengthRemaining} += length($_[0]);
    }
    else {
        my $len = length $_[0];

        if($len > *$self->{BufferOffset}) {
            *$self->{Prime} = substr($_[0], 0, $len - *$self->{BufferOffset}) . *$self->{Prime} ;
            *$self->{InputLengthRemaining} = *$self->{InputLength};
            *$self->{BufferOffset} = 0
        }
        else {
            *$self->{InputLengthRemaining} += length($_[0]);
            *$self->{BufferOffset} -= length($_[0]) ;
        }
    }
}

sub smartSeek
{
    my $self   = shift ;
    my $offset = shift ;
    my $truncate = shift;
    #print "smartSeek to $offset\n";

    # TODO -- need to take prime into account
    if (defined *$self->{FH})
      { *$self->{FH}->seek($offset, SEEK_SET) }
    else {
        *$self->{BufferOffset} = $offset ;
        substr(${ *$self->{Buffer} }, *$self->{BufferOffset}) = ''
            if $truncate;
        return 1;
    }
}

sub smartWrite
{
    my $self   = shift ;
    my $out_data = shift ;

    if (defined *$self->{FH}) {
        # flush needed for 5.8.0 
        defined *$self->{FH}->write($out_data, length $out_data) &&
        defined *$self->{FH}->flush() ;
    }
    else {
       my $buf = *$self->{Buffer} ;
       substr($$buf, *$self->{BufferOffset}, length $out_data) = $out_data ;
       *$self->{BufferOffset} += length($out_data) ;
       return 1;
    }
}

sub smartReadExact
{
    return $_[0]->smartRead($_[1], $_[2]) == $_[2];
}

sub smartEof
{
    my ($self) = $_[0];
    local $.; 

    return 0 if length *$self->{Prime} || *$self->{PushMode};

    if (defined *$self->{FH})
    {
        # Could use
        #
        #  *$self->{FH}->eof() 
        #
        # here, but this can cause trouble if
        # the filehandle is itself a tied handle, but it uses sysread.
        # Then we get into mixing buffered & non-buffered IO, which will cause trouble

        my $info = $self->getErrInfo();
        
        my $buffer = '';
        my $status = $self->smartRead(\$buffer, 1);
        $self->pushBack($buffer) if length $buffer;
        $self->setErrInfo($info);
        
        return $status == 0 ;
    }
    elsif (defined *$self->{InputEvent})
     { *$self->{EventEof} }
    else 
     { *$self->{BufferOffset} >= length(${ *$self->{Buffer} }) }
}

sub clearError
{
    my $self   = shift ;

    *$self->{ErrorNo}  =  0 ;
    ${ *$self->{Error} } = '' ;
}

sub getErrInfo
{
    my $self   = shift ;

    return [ *$self->{ErrorNo}, ${ *$self->{Error} } ] ;
}

sub setErrInfo
{
    my $self   = shift ;
    my $ref    = shift;

    *$self->{ErrorNo}  =  $ref->[0] ;
    ${ *$self->{Error} } = $ref->[1] ;
}

sub saveStatus
{
    my $self   = shift ;
    my $errno = shift() + 0 ;
    #return $errno unless $errno || ! defined *$self->{ErrorNo};
    #return $errno unless $errno ;

    *$self->{ErrorNo}  = $errno;
    ${ *$self->{Error} } = '' ;

    return *$self->{ErrorNo} ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;

    #return $retval if ${ *$self->{Error} };

    ${ *$self->{Error} } = shift ;
    *$self->{ErrorNo} = shift() + 0 if @_ ;

    #warn "saveErrorString: " . ${ *$self->{Error} } . " " . *$self->{Error} . "\n" ;
    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    croak $_[0];
}


sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}

sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return *$self->{ErrorNo};
}

sub HeaderError
{
    my ($self) = shift;
    return $self->saveErrorString(undef, "Header Error: $_[0]", STATUS_ERROR);
}

sub TrailerError
{
    my ($self) = shift;
    return $self->saveErrorString(G_ERR, "Trailer Error: $_[0]", STATUS_ERROR);
}

sub TruncatedHeader
{
    my ($self) = shift;
    return $self->HeaderError("Truncated in $_[0] Section");
}

sub TruncatedTrailer
{
    my ($self) = shift;
    return $self->TrailerError("Truncated in $_[0] Section");
}

sub postCheckParams
{
    return 1;
}

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();
    
    my $Valid = {
                    'BlockSize'     => [1, 1, Parse_unsigned, 16 * 1024],
                    'AutoClose'     => [1, 1, Parse_boolean,  0],
                    'Strict'        => [1, 1, Parse_boolean,  0],
                    'Append'        => [1, 1, Parse_boolean,  0],
                    'Prime'         => [1, 1, Parse_any,      undef],
                    'MultiStream'   => [1, 1, Parse_boolean,  0],
                    'Transparent'   => [1, 1, Parse_any,      1],
                    'Scan'          => [1, 1, Parse_boolean,  0],
                    'InputLength'   => [1, 1, Parse_unsigned, undef],
                    'BinModeOut'    => [1, 1, Parse_boolean,  0],
                    #'Encode'        => [1, 1, Parse_any,       undef],

                   #'ConsumeInput'  => [1, 1, Parse_boolean,  0],

                    $self->getExtraParams(),

                    #'Todo - Revert to ordinary file on end Z_STREAM_END'=> 0,
                    # ContinueAfterEof
                } ;

    $Valid->{TrailingData} = [1, 1, Parse_writable_scalar, undef]
        if  *$self->{OneShot} ;
        
    $got->parse($Valid, @_ ) 
        or $self->croakError("${class}: $got->{Error}")  ;

    $self->postCheckParams($got) 
        or $self->croakError("${class}: " . $self->error())  ;

    return $got;
}

sub _create
{
    my $obj = shift;
    my $got = shift;
    my $append_mode = shift ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Input parameter")
        if ! @_ && ! $got ;

    my $inValue = shift ;

    *$obj->{OneShot}           = 0 ;

    if (! $got)
    {
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $inType  = whatIsInput($inValue, 1);

    $obj->ckInputParam($class, $inValue, 1) 
        or return undef ;

    *$obj->{InNew} = 1;

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . *$obj->{Error});

    if ($inType eq 'buffer' || $inType eq 'code') {
        *$obj->{Buffer} = $inValue ;        
        *$obj->{InputEvent} = $inValue 
           if $inType eq 'code' ;
    }
    else {
        if ($inType eq 'handle') {
            *$obj->{FH} = $inValue ;
            *$obj->{Handle} = 1 ;

            # Need to rewind for Scan
            *$obj->{FH}->seek(0, SEEK_SET) 
                if $got->value('Scan');
        }  
        else {    
            no warnings ;
            my $mode = '<';
            $mode = '+<' if $got->value('Scan');
            *$obj->{StdIO} = ($inValue eq '-');
            *$obj->{FH} = new IO::File "$mode $inValue"
                or return $obj->saveErrorString(undef, "cannot open file '$inValue': $!", $!) ;
        }
        
        *$obj->{LineNo} = $. = 0;
        setBinModeInput(*$obj->{FH}) ;

        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

    if ($got->parsed('Encode')) { 
        my $want_encoding = $got->value('Encode');
        *$obj->{Encoding} = getEncoding($obj, $class, $want_encoding);
    }


    *$obj->{InputLength}       = $got->parsed('InputLength') 
                                    ? $got->value('InputLength')
                                    : undef ;
    *$obj->{InputLengthRemaining} = $got->value('InputLength');
    *$obj->{BufferOffset}      = 0 ;
    *$obj->{AutoClose}         = $got->value('AutoClose');
    *$obj->{Strict}            = $got->value('Strict');
    *$obj->{BlockSize}         = $got->value('BlockSize');
    *$obj->{Append}            = $got->value('Append');
    *$obj->{AppendOutput}      = $append_mode || $got->value('Append');
    *$obj->{ConsumeInput}      = $got->value('ConsumeInput');
    *$obj->{Transparent}       = $got->value('Transparent');
    *$obj->{MultiStream}       = $got->value('MultiStream');

    # TODO - move these two into RawDeflate
    *$obj->{Scan}              = $got->value('Scan');
    *$obj->{ParseExtra}        = $got->value('ParseExtra') 
                                  || $got->value('Strict')  ;
    *$obj->{Type}              = '';
    *$obj->{Prime}             = $got->value('Prime') || '' ;
    *$obj->{Pending}           = '';
    *$obj->{Plain}             = 0;
    *$obj->{PlainBytesRead}    = 0;
    *$obj->{InflatedBytesRead} = 0;
    *$obj->{UnCompSize}        = new U64;
    *$obj->{CompSize}          = new U64;
    *$obj->{TotalInflatedBytesRead} = 0;
    *$obj->{NewStream}         = 0 ;
    *$obj->{EventEof}          = 0 ;
    *$obj->{ClassName}         = $class ;
    *$obj->{Params}            = $got ;

    if (*$obj->{ConsumeInput}) {
        *$obj->{InNew} = 0;
        *$obj->{Closed} = 0;
        return $obj
    }

    my $status = $obj->mkUncomp($got);

    return undef
        unless defined $status;

    if ( !  $status) {
        return undef 
            unless *$obj->{Transparent};

        $obj->clearError();
        *$obj->{Type} = 'plain';
        *$obj->{Plain} = 1;
        #$status = $obj->mkIdentityUncomp($class, $got);
        $obj->pushBack(*$obj->{HeaderPending})  ;
    }

    push @{ *$obj->{InfoList} }, *$obj->{Info} ;

    $obj->saveStatus(STATUS_OK) ;
    *$obj->{InNew} = 0;
    *$obj->{Closed} = 0;

    return $obj;
}

sub ckInputParam
{
    my $self = shift ;
    my $from = shift ;
    my $inType = whatIsInput($_[0], $_[1]);

    $self->croakError("$from: input parameter not a filename, filehandle, array ref or scalar ref")
        if ! $inType ;

#    if ($inType  eq 'filename' )
#    {
#        return $self->saveErrorString(1, "$from: input filename is undef or null string", STATUS_ERROR)
#            if ! defined $_[0] || $_[0] eq ''  ;
#
#        if ($_[0] ne '-' && ! -e $_[0] )
#        {
#            return $self->saveErrorString(1, 
#                            "input file '$_[0]' does not exist", STATUS_ERROR);
#        }
#    }

    return 1;
}


sub _inf
{
    my $obj = shift ;

    my $class = (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;


    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;
    
    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;
    
    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    if ($got->parsed('TrailingData'))
    {
        *$obj->{TrailingData} = $got->value('TrailingData');
    }

    *$obj->{MultiStream} = $got->value('MultiStream');
    $got->value('MultiStream', 0);

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k} 
#                unless defined $v ;
#
#            $obj->_singleTarget($x, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }
    
    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames' 
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';
        
        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $in, $output, @_)
                or return undef ;
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, $input, $output, @_);

    croak "should not be here" ;
}

sub retErr
{
    my $x = shift ;
    my $string = shift ;

    ${ $x->{Error} } = $string ;

    return undef ;
}

sub _singleTarget
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
    
    my $buff = '';
    $x->{buff} = \$buff ;

    my $fh ;
    if ($x->{outType} eq 'filename') {
        my $mode = '>' ;
        $mode = '>>'
            if $x->{Got}->value('Append') ;
        $x->{fh} = new IO::File "$mode $output" 
            or return retErr($x, "cannot open file '$output': $!") ;
        binmode $x->{fh} if $x->{Got}->valueOrDefault('BinModeOut');

    }

    elsif ($x->{outType} eq 'handle') {
        $x->{fh} = $output;
        binmode $x->{fh} if $x->{Got}->valueOrDefault('BinModeOut');
        if ($x->{Got}->value('Append')) {
                seek($x->{fh}, 0, SEEK_END)
                    or return retErr($x, "Cannot seek to end of output filehandle: $!") ;
            }
    }

    
    elsif ($x->{outType} eq 'buffer' )
    {
        $$output = '' 
            unless $x->{Got}->value('Append');
        $x->{buff} = $output ;
    }

    if ($x->{oneInput})
    {
        defined $self->_rd2($x, $input, $output)
            or return undef; 
    }
    else
    {
        for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        {
            defined $self->_rd2($x, $element, $output) 
                or return undef ;
        }
    }


    if ( ($x->{outType} eq 'filename' && $output ne '-') || 
         ($x->{outType} eq 'handle' && $x->{Got}->value('AutoClose'))) {
        $x->{fh}->close() 
            or return retErr($x, $!); 
        delete $x->{fh};
    }

    return 1 ;
}

sub _rd2
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
        
    my $z = createSelfTiedObject($x->{Class}, *$self->{Error});
    
    $z->_create($x->{Got}, 1, $input, @_)
        or return undef ;

    my $status ;
    my $fh = $x->{fh};
    
    while (1) {

        while (($status = $z->read($x->{buff})) > 0) {
            if ($fh) {
                print $fh ${ $x->{buff} }
                    or return $z->saveErrorString(undef, "Error writing to output file: $!", $!);
                ${ $x->{buff} } = '' ;
            }
        }

        if (! $x->{oneOutput} ) {
            my $ot = $x->{outType} ;

            if ($ot eq 'array') 
              { push @$output, $x->{buff} }
            elsif ($ot eq 'hash') 
              { $output->{$input} = $x->{buff} }

            my $buff = '';
            $x->{buff} = \$buff;
        }

        last if $status < 0 || $z->smartEof();
        #last if $status < 0 ;

        last 
            unless *$self->{MultiStream};

        $status = $z->nextStream();

        last 
            unless $status == 1 ;
    }

    return $z->closeError(undef)
        if $status < 0 ;

    ${ *$self->{TrailingData} } = $z->trailingData()
        if defined *$self->{TrailingData} ;

    $z->close() 
        or return undef ;

    return 1 ;
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;

}
  
sub UNTIE
{
    my $self = shift ;
}


sub getHeaderInfo
{
    my $self = shift ;
    wantarray ? @{ *$self->{InfoList} } : *$self->{Info};
}

sub readBlock
{
    my $self = shift ;
    my $buff = shift ;
    my $size = shift ;

    if (defined *$self->{CompressedInputLength}) {
        if (*$self->{CompressedInputLengthRemaining} == 0) {
            delete *$self->{CompressedInputLength};
            *$self->{CompressedInputLengthDone} = 1;
            return STATUS_OK ;
        }
        $size = min($size, *$self->{CompressedInputLengthRemaining} );
        *$self->{CompressedInputLengthRemaining} -= $size ;
    }
    
    my $status = $self->smartRead($buff, $size) ;
    return $self->saveErrorString(STATUS_ERROR, "Error Reading Data: $!")
        if $status == STATUS_ERROR  ;

    if ($status == 0 ) {
        *$self->{Closed} = 1 ;
        *$self->{EndStream} = 1 ;
        return $self->saveErrorString(STATUS_ERROR, "unexpected end of file", STATUS_ERROR);
    }

    return STATUS_OK;
}

sub postBlockChk
{
    return STATUS_OK;
}

sub _raw_read
{
    # return codes
    # >0 - ok, number of bytes read
    # =0 - ok, eof
    # <0 - not ok
    
    my $self = shift ;

    return G_EOF if *$self->{Closed} ;
    #return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;
    return G_EOF if *$self->{EndStream} ;

    my $buffer = shift ;
    my $scan_mode = shift ;

    if (*$self->{Plain}) {
        my $tmp_buff ;
        my $len = $self->smartRead(\$tmp_buff, *$self->{BlockSize}) ;
        
        return $self->saveErrorString(G_ERR, "Error reading data: $!", $!) 
                if $len == STATUS_ERROR ;

        if ($len == 0 ) {
            *$self->{EndStream} = 1 ;
        }
        else {
            *$self->{PlainBytesRead} += $len ;
            $$buffer .= $tmp_buff;
        }

        return $len ;
    }

    if (*$self->{NewStream}) {

        $self->gotoNextStream() > 0
            or return G_ERR;

        # For the headers that actually uncompressed data, put the
        # uncompressed data into the output buffer.
        $$buffer .=  *$self->{Pending} ;
        my $len = length  *$self->{Pending} ;
        *$self->{Pending} = '';
        return $len; 
    }

    my $temp_buf = '';
    my $outSize = 0;
    my $status = $self->readBlock(\$temp_buf, *$self->{BlockSize}, $outSize) ;
    return G_ERR
        if $status == STATUS_ERROR  ;

    my $buf_len = 0;
    if ($status == STATUS_OK) {
        my $beforeC_len = length $temp_buf;
        my $before_len = defined $$buffer ? length $$buffer : 0 ;
        $status = *$self->{Uncomp}->uncompr(\$temp_buf, $buffer,
                                    defined *$self->{CompressedInputLengthDone} ||
                                                $self->smartEof(), $outSize);
                                                
        # Remember the input buffer if it wasn't consumed completely
        $self->pushBack($temp_buf) if *$self->{Uncomp}{ConsumesInput};

        return $self->saveErrorString(G_ERR, *$self->{Uncomp}{Error}, *$self->{Uncomp}{ErrorNo})
            if $self->saveStatus($status) == STATUS_ERROR;    

        $self->postBlockChk($buffer, $before_len) == STATUS_OK
            or return G_ERR;

        $buf_len = defined $$buffer ? length($$buffer) - $before_len : 0;
    
        *$self->{CompSize}->add($beforeC_len - length $temp_buf) ;

        *$self->{InflatedBytesRead} += $buf_len ;
        *$self->{TotalInflatedBytesRead} += $buf_len ;
        *$self->{UnCompSize}->add($buf_len) ;

        $self->filterUncompressed($buffer);

        if (*$self->{Encoding}) {
            $$buffer = *$self->{Encoding}->decode($$buffer);
        }
    }

    if ($status == STATUS_ENDSTREAM) {

        *$self->{EndStream} = 1 ;
#$self->pushBack($temp_buf)  ;
#$temp_buf = '';

        my $trailer;
        my $trailer_size = *$self->{Info}{TrailerLength} ;
        my $got = 0;
        if (*$self->{Info}{TrailerLength})
        {
            $got = $self->smartRead(\$trailer, $trailer_size) ;
        }

        if ($got == $trailer_size) {
            $self->chkTrailer($trailer) == STATUS_OK
                or return G_ERR;
        }
        else {
            return $self->TrailerError("trailer truncated. Expected " . 
                                      "$trailer_size bytes, got $got")
                if *$self->{Strict};
            $self->pushBack($trailer)  ;
        }

        # TODO - if want to file file pointer, do it here

        if (! $self->smartEof()) {
            *$self->{NewStream} = 1 ;

            if (*$self->{MultiStream}) {
                *$self->{EndStream} = 0 ;
                return $buf_len ;
            }
        }

    }
    

    # return the number of uncompressed bytes read
    return $buf_len ;
}

sub reset
{
    my $self = shift ;

    return *$self->{Uncomp}->reset();
}

sub filterUncompressed
{
}

#sub isEndStream
#{
#    my $self = shift ;
#    return *$self->{NewStream} ||
#           *$self->{EndStream} ;
#}

sub nextStream
{
    my $self = shift ;

    my $status = $self->gotoNextStream();
    $status == 1
        or return $status ;

    *$self->{TotalInflatedBytesRead} = 0 ;
    *$self->{LineNo} = $. = 0;

    return 1;
}

sub gotoNextStream
{
    my $self = shift ;

    if (! *$self->{NewStream}) {
        my $status = 1;
        my $buffer ;

        # TODO - make this more efficient if know the offset for the end of
        # the stream and seekable
        $status = $self->read($buffer) 
            while $status > 0 ;

        return $status
            if $status < 0;
    }

    *$self->{NewStream} = 0 ;
    *$self->{EndStream} = 0 ;
    $self->reset();
    *$self->{UnCompSize}->reset();
    *$self->{CompSize}->reset();

    my $magic = $self->ckMagic();
    #*$self->{EndStream} = 0 ;

    if ( ! defined $magic) {
        if (! *$self->{Transparent} || $self->eof())
        {
            *$self->{EndStream} = 1 ;
            return 0;
        }

        $self->clearError();
        *$self->{Type} = 'plain';
        *$self->{Plain} = 1;
        $self->pushBack(*$self->{HeaderPending})  ;
    }
    else
    {
        *$self->{Info} = $self->readHeader($magic);

        if ( ! defined *$self->{Info} ) {
            *$self->{EndStream} = 1 ;
            return -1;
        }
    }

    push @{ *$self->{InfoList} }, *$self->{Info} ;

    return 1; 
}

sub streamCount
{
    my $self = shift ;
    return 1 if ! defined *$self->{InfoList};
    return scalar @{ *$self->{InfoList} }  ;
}

sub read
{
    # return codes
    # >0 - ok, number of bytes read
    # =0 - ok, eof
    # <0 - not ok
    
    my $self = shift ;

    return G_EOF if *$self->{Closed} ;

    my $buffer ;

    if (ref $_[0] ) {
        $self->croakError(*$self->{ClassName} . "::read: buffer parameter is read-only")
            if readonly(${ $_[0] });

        $self->croakError(*$self->{ClassName} . "::read: not a scalar reference $_[0]" )
            unless ref $_[0] eq 'SCALAR' ;
        $buffer = $_[0] ;
    }
    else {
        $self->croakError(*$self->{ClassName} . "::read: buffer parameter is read-only")
            if readonly($_[0]);

        $buffer = \$_[0] ;
    }

    my $length = $_[1] ;
    my $offset = $_[2] || 0;

    if (! *$self->{AppendOutput}) {
        if (! $offset) {    
            $$buffer = '' ;
        }
        else {
            if ($offset > length($$buffer)) {
                $$buffer .= "\x00" x ($offset - length($$buffer));
            }
            else {
                substr($$buffer, $offset) = '';
            }
        }
    }

    return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;

    # the core read will return 0 if asked for 0 bytes
    return 0 if defined $length && $length == 0 ;

    $length = $length || 0;

    $self->croakError(*$self->{ClassName} . "::read: length parameter is negative")
        if $length < 0 ;

    # Short-circuit if this is a simple read, with no length
    # or offset specified.
    unless ( $length || $offset) {
        if (length *$self->{Pending}) {
            $$buffer .= *$self->{Pending} ;
            my $len = length *$self->{Pending};
            *$self->{Pending} = '' ;
            return $len ;
        }
        else {
            my $len = 0;
            $len = $self->_raw_read($buffer) 
                while ! *$self->{EndStream} && $len == 0 ;
            return $len ;
        }
    }

    # Need to jump through more hoops - either length or offset 
    # or both are specified.
    my $out_buffer = *$self->{Pending} ;
    *$self->{Pending} = '';


    while (! *$self->{EndStream} && length($out_buffer) < $length)
    {
        my $buf_len = $self->_raw_read(\$out_buffer);
        return $buf_len 
            if $buf_len < 0 ;
    }

    $length = length $out_buffer 
        if length($out_buffer) < $length ;

    return 0 
        if $length == 0 ;

    $$buffer = '' 
        if ! defined $$buffer;

    $offset = length $$buffer
        if *$self->{AppendOutput} ;

    *$self->{Pending} = $out_buffer;
    $out_buffer = \*$self->{Pending} ;

    #substr($$buffer, $offset) = substr($$out_buffer, 0, $length, '') ;
    substr($$buffer, $offset) = substr($$out_buffer, 0, $length) ;
    substr($$out_buffer, 0, $length) =  '' ;

    return $length ;
}

sub _getline
{
    my $self = shift ;
    my $status = 0 ;

    # Slurp Mode
    if ( ! defined $/ ) {
        my $data ;
        1 while ($status = $self->read($data)) > 0 ;
        return $status < 0 ? \undef : \$data ;
    }

    # Record Mode
    if ( ref $/ eq 'SCALAR' && ${$/} =~ /^\d+$/ && ${$/} > 0) {
        my $reclen = ${$/} ;
        my $data ;
        $status = $self->read($data, $reclen) ;
        return $status < 0 ? \undef : \$data ;
    }

    # Paragraph Mode
    if ( ! length $/ ) {
        my $paragraph ;    
        while (($status = $self->read($paragraph)) > 0 ) {
            if ($paragraph =~ s/^(.*?\n\n+)//s) {
                *$self->{Pending}  = $paragraph ;
                my $par = $1 ;
                return \$par ;
            }
        }
        return $status < 0 ? \undef : \$paragraph;
    }

    # $/ isn't empty, or a reference, so it's Line Mode.
    {
        my $line ;    
        my $offset;
        my $p = \*$self->{Pending}  ;

        if (length(*$self->{Pending}) && 
                    ($offset = index(*$self->{Pending}, $/)) >=0) {
            my $l = substr(*$self->{Pending}, 0, $offset + length $/ );
            substr(*$self->{Pending}, 0, $offset + length $/) = '';    
            return \$l;
        }

        while (($status = $self->read($line)) > 0 ) {
            my $offset = index($line, $/);
            if ($offset >= 0) {
                my $l = substr($line, 0, $offset + length $/ );
                substr($line, 0, $offset + length $/) = '';    
                $$p = $line;
                return \$l;
            }
        }

        return $status < 0 ? \undef : \$line;
    }
}

sub getline
{
    my $self = shift;
    my $current_append = *$self->{AppendOutput} ;
    *$self->{AppendOutput} = 1;
    my $lineref = $self->_getline();
    $. = ++ *$self->{LineNo} if defined $$lineref ;
    *$self->{AppendOutput} = $current_append;
    return $$lineref ;
}

sub getlines
{
    my $self = shift;
    $self->croakError(*$self->{ClassName} . 
            "::getlines: called in scalar context\n") unless wantarray;
    my($line, @lines);
    push(@lines, $line) 
        while defined($line = $self->getline);
    return @lines;
}

sub READLINE
{
    goto &getlines if wantarray;
    goto &getline;
}

sub getc
{
    my $self = shift;
    my $buf;
    return $buf if $self->read($buf, 1);
    return undef;
}

sub ungetc
{
    my $self = shift;
    *$self->{Pending} = ""  unless defined *$self->{Pending} ;    
    *$self->{Pending} = $_[0] . *$self->{Pending} ;    
}


sub trailingData
{
    my $self = shift ;

    if (defined *$self->{FH} || defined *$self->{InputEvent} ) {
        return *$self->{Prime} ;
    }
    else {
        my $buf = *$self->{Buffer} ;
        my $offset = *$self->{BufferOffset} ;
        return substr($$buf, $offset) ;
    }
}


sub eof
{
    my $self = shift ;

    return (*$self->{Closed} ||
              (!length *$self->{Pending} 
                && ( $self->smartEof() || *$self->{EndStream}))) ;
}

sub tell
{
    my $self = shift ;

    my $in ;
    if (*$self->{Plain}) {
        $in = *$self->{PlainBytesRead} ;
    }
    else {
        $in = *$self->{TotalInflatedBytesRead} ;
    }

    my $pending = length *$self->{Pending} ;

    return 0 if $pending > $in ;
    return $in - $pending ;
}

sub close
{
    # todo - what to do if close is called before the end of the gzip file
    #        do we remember any trailing data?
    my $self = shift ;

    return 1 if *$self->{Closed} ;

    untie *$self 
        if $] >= 5.008 ;

    my $status = 1 ;

    if (defined *$self->{FH}) {
        if ((! *$self->{Handle} || *$self->{AutoClose}) && ! *$self->{StdIO}) {
        #if ( *$self->{AutoClose}) {
            local $.; 
            $! = 0 ;
            $status = *$self->{FH}->close();
            return $self->saveErrorString(0, $!, $!)
                if !*$self->{InNew} && $self->saveStatus($!) != 0 ;
        }
        delete *$self->{FH} ;
        $! = 0 ;
    }
    *$self->{Closed} = 1 ;

    return 1;
}

sub DESTROY
{
    my $self = shift ;
    local ($., $@, $!, $^E, $?);

    $self->close() ;
}

sub seek
{
    my $self     = shift ;
    my $position = shift;
    my $whence   = shift ;

    my $here = $self->tell() ;
    my $target = 0 ;


    if ($whence == SEEK_SET) {
        $target = $position ;
    }
    elsif ($whence == SEEK_CUR) {
        $target = $here + $position ;
    }
    elsif ($whence == SEEK_END) {
        $target = $position ;
        $self->croakError(*$self->{ClassName} . "::seek: SEEK_END not allowed") ;
    }
    else {
        $self->croakError(*$self->{ClassName} ."::seek: unknown value, $whence, for whence parameter");
    }

    # short circuit if seeking to current offset
    if ($target == $here) {
        # On ordinary filehandles, seeking to the current
        # position also clears the EOF condition, so we
        # emulate this behavior locally while simultaneously
        # cascading it to the underlying filehandle
        if (*$self->{Plain}) {
            *$self->{EndStream} = 0;
            seek(*$self->{FH},0,1) if *$self->{FH};
        }
        return 1;
    }

    # Outlaw any attempt to seek backwards
    $self->croakError( *$self->{ClassName} ."::seek: cannot seek backwards")
        if $target < $here ;

    # Walk the file to the new offset
    my $offset = $target - $here ;

    my $got;
    while (($got = $self->read(my $buffer, min($offset, *$self->{BlockSize})) ) > 0)
    {
        $offset -= $got;
        last if $offset == 0 ;
    }

    $here = $self->tell() ;
    return $offset == 0 ? 1 : 0 ;
}

sub fileno
{
    my $self = shift ;
    return defined *$self->{FH} 
           ? fileno *$self->{FH} 
           : undef ;
}

sub binmode
{
    1;
#    my $self     = shift ;
#    return defined *$self->{FH} 
#            ? binmode *$self->{FH} 
#            : 1 ;
}

sub opened
{
    my $self     = shift ;
    return ! *$self->{Closed} ;
}

sub autoflush
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->autoflush(@_) 
            : undef ;
}

sub input_line_number
{
    my $self = shift ;
    my $last = *$self->{LineNo};
    $. = *$self->{LineNo} = $_[1] if @_ ;
    return $last;
}


*BINMODE  = \&binmode;
*SEEK     = \&seek; 
*READ     = \&read;
*sysread  = \&read;
*TELL     = \&tell;
*EOF      = \&eof;

*FILENO   = \&fileno;
*CLOSE    = \&close;

sub _notAvailable
{
    my $name = shift ;
    #return sub { croak "$name Not Available" ; } ;
    return sub { croak "$name Not Available: File opened only for intput" ; } ;
}


*print    = _notAvailable('print');
*PRINT    = _notAvailable('print');
*printf   = _notAvailable('printf');
*PRINTF   = _notAvailable('printf');
*write    = _notAvailable('write');
*WRITE    = _notAvailable('write');

#*sysread  = \&read;
#*syswrite = \&_notAvailable;



package IO::Uncompress::Base ;


1 ;
__END__

#line 1484
FILE    228db72f/IO/Uncompress/Gunzip.pm  ##line 1 "/usr/share/perl/5.14/IO/Uncompress/Gunzip.pm"

package IO::Uncompress::Gunzip ;

require 5.004 ;

# for RFC1952

use strict ;
use warnings;
use bytes;

use IO::Uncompress::RawInflate 2.033 ;

use Compress::Raw::Zlib 2.033 qw( crc32 ) ;
use IO::Compress::Base::Common 2.033 qw(:Status createSelfTiedObject);
use IO::Compress::Gzip::Constants 2.033 ;
use IO::Compress::Zlib::Extra 2.033 ;

require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $GunzipError);

@ISA = qw( Exporter IO::Uncompress::RawInflate );
@EXPORT_OK = qw( $GunzipError gunzip );
%EXPORT_TAGS = %IO::Uncompress::RawInflate::DEFLATE_CONSTANTS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

$GunzipError = '';

$VERSION = '2.033';

sub new
{
    my $class = shift ;
    $GunzipError = '';
    my $obj = createSelfTiedObject($class, \$GunzipError);

    $obj->_create(undef, 0, @_);
}

sub gunzip
{
    my $obj = createSelfTiedObject(undef, \$GunzipError);
    return $obj->_inf(@_) ;
}

sub getExtraParams
{
    use IO::Compress::Base::Common  2.033 qw(:Parse);
    return ( 'ParseExtra' => [1, 1, Parse_boolean,  0] ) ;
}

sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gunzip always needs crc32
    $got->value('CRC32' => 1);

    return 1;
}

sub ckMagic
{
    my $self = shift;

    my $magic ;
    $self->smartReadExact(\$magic, GZIP_ID_SIZE);

    *$self->{HeaderPending} = $magic ;

    return $self->HeaderError("Minimum header size is " . 
                              GZIP_MIN_HEADER_SIZE . " bytes") 
        if length $magic != GZIP_ID_SIZE ;                                    

    return $self->HeaderError("Bad Magic")
        if ! isGzipMagic($magic) ;

    *$self->{Type} = 'rfc1952';

    return $magic ;
}

sub readHeader
{
    my $self = shift;
    my $magic = shift;

    return $self->_readGzipHeader($magic);
}

sub chkTrailer
{
    my $self = shift;
    my $trailer = shift;

    # Check CRC & ISIZE 
    my ($CRC32, $ISIZE) = unpack("V V", $trailer) ;
    *$self->{Info}{CRC32} = $CRC32;    
    *$self->{Info}{ISIZE} = $ISIZE;    

    if (*$self->{Strict}) {
        return $self->TrailerError("CRC mismatch")
            if $CRC32 != *$self->{Uncomp}->crc32() ;

        my $exp_isize = *$self->{UnCompSize}->get32bit();
        return $self->TrailerError("ISIZE mismatch. Got $ISIZE"
                                  . ", expected $exp_isize")
            if $ISIZE != $exp_isize ;
    }

    return STATUS_OK;
}

sub isGzipMagic
{
    my $buffer = shift ;
    return 0 if length $buffer < GZIP_ID_SIZE ;
    my ($id1, $id2) = unpack("C C", $buffer) ;
    return $id1 == GZIP_ID1 && $id2 == GZIP_ID2 ;
}

sub _readFullGzipHeader($)
{
    my ($self) = @_ ;
    my $magic = '' ;

    $self->smartReadExact(\$magic, GZIP_ID_SIZE);

    *$self->{HeaderPending} = $magic ;

    return $self->HeaderError("Minimum header size is " . 
                              GZIP_MIN_HEADER_SIZE . " bytes") 
        if length $magic != GZIP_ID_SIZE ;                                    


    return $self->HeaderError("Bad Magic")
        if ! isGzipMagic($magic) ;

    my $status = $self->_readGzipHeader($magic);
    delete *$self->{Transparent} if ! defined $status ;
    return $status ;
}

sub _readGzipHeader($)
{
    my ($self, $magic) = @_ ;
    my ($HeaderCRC) ;
    my ($buffer) = '' ;

    $self->smartReadExact(\$buffer, GZIP_MIN_HEADER_SIZE - GZIP_ID_SIZE)
        or return $self->HeaderError("Minimum header size is " . 
                                     GZIP_MIN_HEADER_SIZE . " bytes") ;

    my $keep = $magic . $buffer ;
    *$self->{HeaderPending} = $keep ;

    # now split out the various parts
    my ($cm, $flag, $mtime, $xfl, $os) = unpack("C C V C C", $buffer) ;

    $cm == GZIP_CM_DEFLATED 
        or return $self->HeaderError("Not Deflate (CM is $cm)") ;

    # check for use of reserved bits
    return $self->HeaderError("Use of Reserved Bits in FLG field.")
        if $flag & GZIP_FLG_RESERVED ; 

    my $EXTRA ;
    my @EXTRA = () ;
    if ($flag & GZIP_FLG_FEXTRA) {
        $EXTRA = "" ;
        $self->smartReadExact(\$buffer, GZIP_FEXTRA_HEADER_SIZE) 
            or return $self->TruncatedHeader("FEXTRA Length") ;

        my ($XLEN) = unpack("v", $buffer) ;
        $self->smartReadExact(\$EXTRA, $XLEN) 
            or return $self->TruncatedHeader("FEXTRA Body");
        $keep .= $buffer . $EXTRA ;

        if ($XLEN && *$self->{'ParseExtra'}) {
            my $bad = IO::Compress::Zlib::Extra::parseRawExtra($EXTRA,
                                                \@EXTRA, 1, 1);
            return $self->HeaderError($bad)
                if defined $bad;
        }
    }

    my $origname ;
    if ($flag & GZIP_FLG_FNAME) {
        $origname = "" ;
        while (1) {
            $self->smartReadExact(\$buffer, 1) 
                or return $self->TruncatedHeader("FNAME");
            last if $buffer eq GZIP_NULL_BYTE ;
            $origname .= $buffer 
        }
        $keep .= $origname . GZIP_NULL_BYTE ;

        return $self->HeaderError("Non ISO 8859-1 Character found in Name")
            if *$self->{Strict} && $origname =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
    }

    my $comment ;
    if ($flag & GZIP_FLG_FCOMMENT) {
        $comment = "";
        while (1) {
            $self->smartReadExact(\$buffer, 1) 
                or return $self->TruncatedHeader("FCOMMENT");
            last if $buffer eq GZIP_NULL_BYTE ;
            $comment .= $buffer 
        }
        $keep .= $comment . GZIP_NULL_BYTE ;

        return $self->HeaderError("Non ISO 8859-1 Character found in Comment")
            if *$self->{Strict} && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o ;
    }

    if ($flag & GZIP_FLG_FHCRC) {
        $self->smartReadExact(\$buffer, GZIP_FHCRC_SIZE) 
            or return $self->TruncatedHeader("FHCRC");

        $HeaderCRC = unpack("v", $buffer) ;
        my $crc16 = crc32($keep) & 0xFF ;

        return $self->HeaderError("CRC16 mismatch.")
            if *$self->{Strict} && $crc16 != $HeaderCRC;

        $keep .= $buffer ;
    }

    # Assume compression method is deflated for xfl tests
    #if ($xfl) {
    #}

    *$self->{Type} = 'rfc1952';

    return {
        'Type'          => 'rfc1952',
        'FingerprintLength'  => 2,
        'HeaderLength'  => length $keep,
        'TrailerLength' => GZIP_TRAILER_SIZE,
        'Header'        => $keep,
        'isMinimalHeader' => $keep eq GZIP_MINIMUM_HEADER ? 1 : 0,

        'MethodID'      => $cm,
        'MethodName'    => $cm == GZIP_CM_DEFLATED ? "Deflated" : "Unknown" ,
        'TextFlag'      => $flag & GZIP_FLG_FTEXT ? 1 : 0,
        'HeaderCRCFlag' => $flag & GZIP_FLG_FHCRC ? 1 : 0,
        'NameFlag'      => $flag & GZIP_FLG_FNAME ? 1 : 0,
        'CommentFlag'   => $flag & GZIP_FLG_FCOMMENT ? 1 : 0,
        'ExtraFlag'     => $flag & GZIP_FLG_FEXTRA ? 1 : 0,
        'Name'          => $origname,
        'Comment'       => $comment,
        'Time'          => $mtime,
        'OsID'          => $os,
        'OsName'        => defined $GZIP_OS_Names{$os} 
                                 ? $GZIP_OS_Names{$os} : "Unknown",
        'HeaderCRC'     => $HeaderCRC,
        'Flags'         => $flag,
        'ExtraFlags'    => $xfl,
        'ExtraFieldRaw' => $EXTRA,
        'ExtraField'    => [ @EXTRA ],


        #'CompSize'=> $compsize,
        #'CRC32'=> $CRC32,
        #'OrigSize'=> $ISIZE,
      }
}


1;

__END__


#line 1112
FILE   $80efed35/IO/Uncompress/RawInflate.pm  "#line 1 "/usr/share/perl/5.14/IO/Uncompress/RawInflate.pm"
package IO::Uncompress::RawInflate ;
# for RFC1951

use strict ;
use warnings;
use bytes;

use Compress::Raw::Zlib  2.033 ;
use IO::Compress::Base::Common  2.033 qw(:Status createSelfTiedObject);

use IO::Uncompress::Base  2.033 ;
use IO::Uncompress::Adapter::Inflate  2.033 ;

require Exporter ;
our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, %DEFLATE_CONSTANTS, $RawInflateError);

$VERSION = '2.033';
$RawInflateError = '';

@ISA    = qw( Exporter IO::Uncompress::Base );
@EXPORT_OK = qw( $RawInflateError rawinflate ) ;
%DEFLATE_CONSTANTS = ();
%EXPORT_TAGS = %IO::Uncompress::Base::EXPORT_TAGS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

#{
#    # Execute at runtime  
#    my %bad;
#    for my $module (qw(Compress::Raw::Zlib IO::Compress::Base::Common IO::Uncompress::Base IO::Uncompress::Adapter::Inflate))
#    {
#        my $ver = ${ $module . "::VERSION"} ;
#        
#        $bad{$module} = $ver
#            if $ver ne $VERSION;
#    }
#    
#    if (keys %bad)
#    {
#        my $string = join "\n", map { "$_ $bad{$_}" } keys %bad;
#        die caller(0)[0] . "needs version $VERSION mismatch\n$string\n";
#    }
#}

sub new
{
    my $class = shift ;
    my $obj = createSelfTiedObject($class, \$RawInflateError);
    $obj->_create(undef, 0, @_);
}

sub rawinflate
{
    my $obj = createSelfTiedObject(undef, \$RawInflateError);
    return $obj->_inf(@_);
}

sub getExtraParams
{
    return ();
}

sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    return 1;
}

sub mkUncomp
{
    my $self = shift ;
    my $got = shift ;

    my ($obj, $errstr, $errno) = IO::Uncompress::Adapter::Inflate::mkUncompObject(
                                                                $got->value('CRC32'),
                                                                $got->value('ADLER32'),
                                                                $got->value('Scan'),
                                                            );

    return $self->saveErrorString(undef, $errstr, $errno)
        if ! defined $obj;

    *$self->{Uncomp} = $obj;

     my $magic = $self->ckMagic()
        or return 0;

    *$self->{Info} = $self->readHeader($magic)
        or return undef ;

    return 1;

}


sub ckMagic
{
    my $self = shift;

    return $self->_isRaw() ;
}

sub readHeader
{
    my $self = shift;
    my $magic = shift ;

    return {
        'Type'          => 'rfc1951',
        'FingerprintLength'  => 0,
        'HeaderLength'  => 0,
        'TrailerLength' => 0,
        'Header'        => ''
        };
}

sub chkTrailer
{
    return STATUS_OK ;
}

sub _isRaw
{
    my $self   = shift ;

    my $got = $self->_isRawx(@_);

    if ($got) {
        *$self->{Pending} = *$self->{HeaderPending} ;
    }
    else {
        $self->pushBack(*$self->{HeaderPending});
        *$self->{Uncomp}->reset();
    }
    *$self->{HeaderPending} = '';

    return $got ;
}

sub _isRawx
{
    my $self   = shift ;
    my $magic = shift ;

    $magic = '' unless defined $magic ;

    my $buffer = '';

    $self->smartRead(\$buffer, *$self->{BlockSize}) >= 0  
        or return $self->saveErrorString(undef, "No data to read");

    my $temp_buf = $magic . $buffer ;
    *$self->{HeaderPending} = $temp_buf ;    
    $buffer = '';
    my $status = *$self->{Uncomp}->uncompr(\$temp_buf, \$buffer, $self->smartEof()) ;
    
    return $self->saveErrorString(undef, *$self->{Uncomp}{Error}, STATUS_ERROR)
        if $status == STATUS_ERROR;

    $self->pushBack($temp_buf)  ;

    return $self->saveErrorString(undef, "unexpected end of file", STATUS_ERROR)
        if $self->smartEof() && $status != STATUS_ENDSTREAM;
            
    #my $buf_len = *$self->{Uncomp}->uncompressedBytes();
    my $buf_len = length $buffer;

    if ($status == STATUS_ENDSTREAM) {
        if (*$self->{MultiStream} 
                    && (length $temp_buf || ! $self->smartEof())){
            *$self->{NewStream} = 1 ;
            *$self->{EndStream} = 0 ;
        }
        else {
            *$self->{EndStream} = 1 ;
        }
    }
    *$self->{HeaderPending} = $buffer ;    
    *$self->{InflatedBytesRead} = $buf_len ;    
    *$self->{TotalInflatedBytesRead} += $buf_len ;    
    *$self->{Type} = 'rfc1951';

    $self->saveStatus(STATUS_OK);

    return {
        'Type'          => 'rfc1951',
        'HeaderLength'  => 0,
        'TrailerLength' => 0,
        'Header'        => ''
        };
}


sub inflateSync
{
    my $self = shift ;

    # inflateSync is a no-op in Plain mode
    return 1
        if *$self->{Plain} ;

    return 0 if *$self->{Closed} ;
    #return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;
    return 0 if ! length *$self->{Pending} && *$self->{EndStream} ;

    # Disable CRC check
    *$self->{Strict} = 0 ;

    my $status ;
    while (1)
    {
        my $temp_buf ;

        if (length *$self->{Pending} )
        {
            $temp_buf = *$self->{Pending} ;
            *$self->{Pending} = '';
        }
        else
        {
            $status = $self->smartRead(\$temp_buf, *$self->{BlockSize}) ;
            return $self->saveErrorString(0, "Error Reading Data")
                if $status < 0  ;

            if ($status == 0 ) {
                *$self->{EndStream} = 1 ;
                return $self->saveErrorString(0, "unexpected end of file", STATUS_ERROR);
            }
        }
        
        $status = *$self->{Uncomp}->sync($temp_buf) ;

        if ($status == STATUS_OK)
        {
            *$self->{Pending} .= $temp_buf ;
            return 1 ;
        }

        last unless $status == STATUS_ERROR ;
    }

    return 0;
}

#sub performScan
#{
#    my $self = shift ;
#
#    my $status ;
#    my $end_offset = 0;
#
#    $status = $self->scan() 
#    #or return $self->saveErrorString(undef, "Error Scanning: $$error_ref", $self->errorNo) ;
#        or return $self->saveErrorString(G_ERR, "Error Scanning: $status")
#
#    $status = $self->zap($end_offset) 
#        or return $self->saveErrorString(G_ERR, "Error Zapping: $status");
#    #or return $self->saveErrorString(undef, "Error Zapping: $$error_ref", $self->errorNo) ;
#
#    #(*$obj->{Deflate}, $status) = $inf->createDeflate();
#
##    *$obj->{Header} = *$inf->{Info}{Header};
##    *$obj->{UnCompSize_32bit} = 
##        *$obj->{BytesWritten} = *$inf->{UnCompSize_32bit} ;
##    *$obj->{CompSize_32bit} = *$inf->{CompSize_32bit} ;
#
#
##    if ( $outType eq 'buffer') 
##      { substr( ${ *$self->{Buffer} }, $end_offset) = '' }
##    elsif ($outType eq 'handle' || $outType eq 'filename') {
##        *$self->{FH} = *$inf->{FH} ;
##        delete *$inf->{FH};
##        *$obj->{FH}->flush() ;
##        *$obj->{Handle} = 1 if $outType eq 'handle';
##
##        #seek(*$obj->{FH}, $end_offset, SEEK_SET) 
##        *$obj->{FH}->seek($end_offset, SEEK_SET) 
##            or return $obj->saveErrorString(undef, $!, $!) ;
##    }
#    
#}

sub scan
{
    my $self = shift ;

    return 1 if *$self->{Closed} ;
    return 1 if !length *$self->{Pending} && *$self->{EndStream} ;

    my $buffer = '' ;
    my $len = 0;

    $len = $self->_raw_read(\$buffer, 1) 
        while ! *$self->{EndStream} && $len >= 0 ;

    #return $len if $len < 0 ? $len : 0 ;
    return $len < 0 ? 0 : 1 ;
}

sub zap
{
    my $self  = shift ;

    my $headerLength = *$self->{Info}{HeaderLength};
    my $block_offset =  $headerLength + *$self->{Uncomp}->getLastBlockOffset();
    $_[0] = $headerLength + *$self->{Uncomp}->getEndOffset();
    #printf "# End $_[0], headerlen $headerLength \n";;
    #printf "# block_offset $block_offset %x\n", $block_offset;
    my $byte ;
    ( $self->smartSeek($block_offset) &&
      $self->smartRead(\$byte, 1) ) 
        or return $self->saveErrorString(0, $!, $!); 

    #printf "#byte is %x\n", unpack('C*',$byte);
    *$self->{Uncomp}->resetLastBlockByte($byte);
    #printf "#to byte is %x\n", unpack('C*',$byte);

    ( $self->smartSeek($block_offset) && 
      $self->smartWrite($byte) )
        or return $self->saveErrorString(0, $!, $!); 

    #$self->smartSeek($end_offset, 1);

    return 1 ;
}

sub createDeflate
{
    my $self  = shift ;
    my ($def, $status) = *$self->{Uncomp}->createDeflateStream(
                                    -AppendOutput   => 1,
                                    -WindowBits => - MAX_WBITS,
                                    -CRC32      => *$self->{Params}->value('CRC32'),
                                    -ADLER32    => *$self->{Params}->value('ADLER32'),
                                );
    
    return wantarray ? ($status, $def) : $def ;                                
}


1; 

__END__


#line 1111
FILE   a1c45002/PerlIO.pm  �#line 1 "/usr/share/perl/5.14/PerlIO.pm"
package PerlIO;

our $VERSION = '1.07';

# Map layer name to package that defines it
our %alias;

sub import
{
 my $class = shift;
 while (@_)
  {
   my $layer = shift;
   if (exists $alias{$layer})
    {
     $layer = $alias{$layer}
    }
   else
    {
     $layer = "${class}::$layer";
    }
   eval "require $layer";
   warn $@ if $@;
  }
}

sub F_UTF8 () { 0x8000 }

1;
__END__

#line 333
FILE   4ad2e17a/SelectSaver.pm  �#line 1 "/usr/share/perl/5.14/SelectSaver.pm"
package SelectSaver;

our $VERSION = '1.02';

require 5.000;
use Carp;
use Symbol;

sub new {
    @_ >= 1 && @_ <= 2 or croak 'usage: SelectSaver->new( [FILEHANDLE] )';
    my $fh = select;
    my $self = bless \$fh, $_[0];
    select qualify($_[1], caller) if @_ > 1;
    $self;
}

sub DESTROY {
    my $self = $_[0];
    select $$self;
}

1;
FILE   8c91758b/Symbol.pm  \#line 1 "/usr/share/perl/5.14/Symbol.pm"
package Symbol;

BEGIN { require 5.005; }

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(gensym ungensym qualify qualify_to_ref);
@EXPORT_OK = qw(delete_package geniosym);

$VERSION = '1.07';

my $genpkg = "Symbol::";
my $genseq = 0;

my %global = map {$_ => 1} qw(ARGV ARGVOUT ENV INC SIG STDERR STDIN STDOUT);

#
# Note that we never _copy_ the glob; we just make a ref to it.
# If we did copy it, then SVf_FAKE would be set on the copy, and
# glob-specific behaviors (e.g. C<*$ref = \&func>) wouldn't work.
#
sub gensym () {
    my $name = "GEN" . $genseq++;
    my $ref = \*{$genpkg . $name};
    delete $$genpkg{$name};
    $ref;
}

sub geniosym () {
    my $sym = gensym();
    # force the IO slot to be filled
    select(select $sym);
    *$sym{IO};
}

sub ungensym ($) {}

sub qualify ($;$) {
    my ($name) = @_;
    if (!ref($name) && index($name, '::') == -1 && index($name, "'") == -1) {
	my $pkg;
	# Global names: special character, "^xyz", or other. 
	if ($name =~ /^(([^a-z])|(\^[a-z_]+))\z/i || $global{$name}) {
	    # RGS 2001-11-05 : translate leading ^X to control-char
	    $name =~ s/^\^([a-z_])/'qq(\c'.$1.')'/eei;
	    $pkg = "main";
	}
	else {
	    $pkg = (@_ > 1) ? $_[1] : caller;
	}
	$name = $pkg . "::" . $name;
    }
    $name;
}

sub qualify_to_ref ($;$) {
    return \*{ qualify $_[0], @_ > 1 ? $_[1] : caller };
}

#
# of Safe.pm lineage
#
sub delete_package ($) {
    my $pkg = shift;

    # expand to full symbol table name if needed

    unless ($pkg =~ /^main::.*::$/) {
        $pkg = "main$pkg"	if	$pkg =~ /^::/;
        $pkg = "main::$pkg"	unless	$pkg =~ /^main::/;
        $pkg .= '::'		unless	$pkg =~ /::$/;
    }

    my($stem, $leaf) = $pkg =~ m/(.*::)(\w+::)$/;
    my $stem_symtab = *{$stem}{HASH};
    return unless defined $stem_symtab and exists $stem_symtab->{$leaf};

    # free all the symbols in the package

    my $leaf_symtab = *{$stem_symtab->{$leaf}}{HASH};
    foreach my $name (keys %$leaf_symtab) {
        undef *{$pkg . $name};
    }

    # delete the symbol table

    %$leaf_symtab = ();
    delete $stem_symtab->{$leaf};
}

1;
FILE   aeb07e11/Time/Local.pm  v#line 1 "/usr/share/perl/5.14/Time/Local.pm"
package Time::Local;

require Exporter;
use Carp;
use Config;
use strict;

use vars qw( $VERSION @ISA @EXPORT @EXPORT_OK );
$VERSION   = '1.2000';

@ISA       = qw( Exporter );
@EXPORT    = qw( timegm timelocal );
@EXPORT_OK = qw( timegm_nocheck timelocal_nocheck );

my @MonthDays = ( 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );

# Determine breakpoint for rolling century
my $ThisYear    = ( localtime() )[5];
my $Breakpoint  = ( $ThisYear + 50 ) % 100;
my $NextCentury = $ThisYear - $ThisYear % 100;
$NextCentury += 100 if $Breakpoint < 50;
my $Century = $NextCentury - 100;
my $SecOff  = 0;

my ( %Options, %Cheat );

use constant SECS_PER_MINUTE => 60;
use constant SECS_PER_HOUR   => 3600;
use constant SECS_PER_DAY    => 86400;

my $MaxDay;
if ($] < 5.012000) {
    my $MaxInt;
    if ( $^O eq 'MacOS' ) {
        # time_t is unsigned...
        $MaxInt = ( 1 << ( 8 * $Config{ivsize} ) ) - 1;
    }
    else {
        $MaxInt = ( ( 1 << ( 8 * $Config{ivsize} - 2 ) ) - 1 ) * 2 + 1;
    }

    $MaxDay = int( ( $MaxInt - ( SECS_PER_DAY / 2 ) ) / SECS_PER_DAY ) - 1;
}
else {
    # recent localtime()'s limit is the year 2**31
    $MaxDay = 365 * (2**31);
}

# Determine the EPOC day for this machine
my $Epoc = 0;
if ( $^O eq 'vos' ) {
    # work around posix-977 -- VOS doesn't handle dates in the range
    # 1970-1980.
    $Epoc = _daygm( 0, 0, 0, 1, 0, 70, 4, 0 );
}
elsif ( $^O eq 'MacOS' ) {
    $MaxDay *=2 if $^O eq 'MacOS';  # time_t unsigned ... quick hack?
    # MacOS time() is seconds since 1 Jan 1904, localtime
    # so we need to calculate an offset to apply later
    $Epoc = 693901;
    $SecOff = timelocal( localtime(0)) - timelocal( gmtime(0) ) ;
    $Epoc += _daygm( gmtime(0) );
}
else {
    $Epoc = _daygm( gmtime(0) );
}

%Cheat = ();    # clear the cache as epoc has changed

sub _daygm {

    # This is written in such a byzantine way in order to avoid
    # lexical variables and sub calls, for speed
    return $_[3] + (
        $Cheat{ pack( 'ss', @_[ 4, 5 ] ) } ||= do {
            my $month = ( $_[4] + 10 ) % 12;
            my $year  = $_[5] + 1900 - int($month / 10);

            ( ( 365 * $year )
              + int( $year / 4 )
              - int( $year / 100 )
              + int( $year / 400 )
              + int( ( ( $month * 306 ) + 5 ) / 10 )
            )
            - $Epoc;
        }
    );
}

sub _timegm {
    my $sec =
        $SecOff + $_[0] + ( SECS_PER_MINUTE * $_[1] ) + ( SECS_PER_HOUR * $_[2] );

    return $sec + ( SECS_PER_DAY * &_daygm );
}

sub timegm {
    my ( $sec, $min, $hour, $mday, $month, $year ) = @_;

    if ( $year >= 1000 ) {
        $year -= 1900;
    }
    elsif ( $year < 100 and $year >= 0 ) {
        $year += ( $year > $Breakpoint ) ? $Century : $NextCentury;
    }

    unless ( $Options{no_range_check} ) {
        croak "Month '$month' out of range 0..11"
            if $month > 11
            or $month < 0;

	my $md = $MonthDays[$month];
        ++$md
            if $month == 1 && _is_leap_year( $year + 1900 );

        croak "Day '$mday' out of range 1..$md"  if $mday > $md or $mday < 1;
        croak "Hour '$hour' out of range 0..23"  if $hour > 23  or $hour < 0;
        croak "Minute '$min' out of range 0..59" if $min > 59   or $min < 0;
        croak "Second '$sec' out of range 0..59" if $sec > 59   or $sec < 0;
    }

    my $days = _daygm( undef, undef, undef, $mday, $month, $year );

    unless ($Options{no_range_check} or abs($days) < $MaxDay) {
        my $msg = '';
        $msg .= "Day too big - $days > $MaxDay\n" if $days > $MaxDay;

	$year += 1900;
        $msg .=  "Cannot handle date ($sec, $min, $hour, $mday, $month, $year)";

	croak $msg;
    }

    return $sec
           + $SecOff
           + ( SECS_PER_MINUTE * $min )
           + ( SECS_PER_HOUR * $hour )
           + ( SECS_PER_DAY * $days );
}

sub _is_leap_year {
    return 0 if $_[0] % 4;
    return 1 if $_[0] % 100;
    return 0 if $_[0] % 400;

    return 1;
}

sub timegm_nocheck {
    local $Options{no_range_check} = 1;
    return &timegm;
}

sub timelocal {
    my $ref_t = &timegm;
    my $loc_for_ref_t = _timegm( localtime($ref_t) );

    my $zone_off = $loc_for_ref_t - $ref_t
        or return $loc_for_ref_t;

    # Adjust for timezone
    my $loc_t = $ref_t - $zone_off;

    # Are we close to a DST change or are we done
    my $dst_off = $ref_t - _timegm( localtime($loc_t) );

    # If this evaluates to true, it means that the value in $loc_t is
    # the _second_ hour after a DST change where the local time moves
    # backward.
    if ( ! $dst_off &&
         ( ( $ref_t - SECS_PER_HOUR ) - _timegm( localtime( $loc_t - SECS_PER_HOUR ) ) < 0 )
       ) {
        return $loc_t - SECS_PER_HOUR;
    }

    # Adjust for DST change
    $loc_t += $dst_off;

    return $loc_t if $dst_off > 0;

    # If the original date was a non-extent gap in a forward DST jump,
    # we should now have the wrong answer - undo the DST adjustment
    my ( $s, $m, $h ) = localtime($loc_t);
    $loc_t -= $dst_off if $s != $_[0] || $m != $_[1] || $h != $_[2];

    return $loc_t;
}

sub timelocal_nocheck {
    local $Options{no_range_check} = 1;
    return &timelocal;
}

1;

__END__

#line 385
FILE   ca4ba019/UNIVERSAL.pm  �#line 1 "/usr/share/perl/5.14/UNIVERSAL.pm"
package UNIVERSAL;

our $VERSION = '1.08';

# UNIVERSAL should not contain any extra subs/methods beyond those
# that it exists to define. The use of Exporter below is a historical
# accident that can't be fixed without breaking code.  Note that we
# *don't* set @ISA here, as we don't want all classes/objects inheriting from
# Exporter.  It's bad enough that all classes have a import() method
# whenever UNIVERSAL.pm is loaded.
require Exporter;
@EXPORT_OK = qw(isa can VERSION);

# Make sure that even though the import method is called, it doesn't do
# anything unless called on UNIVERSAL.
sub import {
    return unless $_[0] eq __PACKAGE__;
    return unless @_ > 1;
    require warnings;
    warnings::warnif(
      'deprecated',
      'UNIVERSAL->import is deprecated and will be removed in a future perl',
    );
    goto &Exporter::import;
}

1;
__END__

#line 215
FILE   5c529309/XSLoader.pm  �#line 1 "/usr/share/perl/5.14/XSLoader.pm"
# Generated from XSLoader.pm.PL (resolved %Config::Config value)

package XSLoader;

$VERSION = "0.13";

#use strict;

# enable debug/trace messages from DynaLoader perl code
# $dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

package DynaLoader;

# No prizes for guessing why we don't say 'bootstrap DynaLoader;' here.
# NOTE: All dl_*.xs (including dl_none.xs) define a dl_error() XSUB
boot_DynaLoader('DynaLoader') if defined(&boot_DynaLoader) &&
                                !defined(&dl_error);
package XSLoader;

sub load {
    package DynaLoader;

    my ($module, $modlibname) = caller();

    if (@_) {
	$module = $_[0];
    } else {
	$_[0] = $module;
    }

    # work with static linking too
    my $boots = "$module\::bootstrap";
    goto &$boots if defined &$boots;

    goto \&XSLoader::bootstrap_inherit;

    my @modparts = split(/::/,$module);
    my $modfname = $modparts[-1];

    my $modpname = join('/',@modparts);
    my $c = @modparts;
    $modlibname =~ s,[\\/][^\\/]+$,, while $c--;	# Q&D basename
    my $file = "$modlibname/auto/$modpname/$modfname.so";

#   print STDERR "XSLoader::load for $module ($file)\n" if $dl_debug;

    my $bs = $file;
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/; # look for .bs 'beside' the library

    if (-s $bs) { # only read file if it's not empty
#       print STDERR "BS: $bs ($^O, $dlsrc)\n" if $dl_debug;
        eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    goto \&XSLoader::bootstrap_inherit if not -f $file or -s $bs;

    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @DynaLoader::dl_require_symbols = ($bootname);

    my $boot_symbol_ref;

    # Many dynamic extension loading problems will appear to come from
    # this section of code: XYZ failed at line 123 of DynaLoader.pm.
    # Often these errors are actually occurring in the initialisation
    # C code of the extension XS file. Perl reports the error as being
    # in this perl code simply because this was the last perl code
    # it executed.

    my $libref = dl_load_file($file, 0) or do { 
        require Carp;
        Carp::croak("Can't load '$file' for module $module: " . dl_error());
    };
    push(@DynaLoader::dl_librefs,$libref);  # record loaded object

    my @unresolved = dl_undef_symbols();
    if (@unresolved) {
        require Carp;
        Carp::carp("Undefined symbols present after loading $file: @unresolved\n");
    }

    $boot_symbol_ref = dl_find_symbol($libref, $bootname) or do {
        require Carp;
        Carp::croak("Can't find '$bootname' symbol in $file\n");
    };

    push(@DynaLoader::dl_modules, $module); # record loaded module

  boot:
    my $xs = dl_install_xsub($boots, $boot_symbol_ref, $file);

    # See comment block above
    push(@DynaLoader::dl_shared_objects, $file); # record files loaded
    return &$xs(@_);
}

sub bootstrap_inherit {
    require DynaLoader;
    goto \&DynaLoader::bootstrap_inherit;
}

1;

__END__

FILE   b655ed5d/base.pm  ;#line 1 "/usr/share/perl/5.14/base.pm"
package base;

use strict 'vars';
use vars qw($VERSION);
$VERSION = '2.16';
$VERSION = eval $VERSION;

# constant.pm is slow
sub SUCCESS () { 1 }

sub PUBLIC     () { 2**0  }
sub PRIVATE    () { 2**1  }
sub INHERITED  () { 2**2  }
sub PROTECTED  () { 2**3  }

my $Fattr = \%fields::attr;

sub has_fields {
    my($base) = shift;
    my $fglob = ${"$base\::"}{FIELDS};
    return( ($fglob && 'GLOB' eq ref($fglob) && *$fglob{HASH}) ? 1 : 0 );
}

sub has_version {
    my($base) = shift;
    my $vglob = ${$base.'::'}{VERSION};
    return( ($vglob && *$vglob{SCALAR}) ? 1 : 0 );
}

sub has_attr {
    my($proto) = shift;
    my($class) = ref $proto || $proto;
    return exists $Fattr->{$class};
}

sub get_attr {
    $Fattr->{$_[0]} = [1] unless $Fattr->{$_[0]};
    return $Fattr->{$_[0]};
}

if ($] < 5.009) {
    *get_fields = sub {
        # Shut up a possible typo warning.
        () = \%{$_[0].'::FIELDS'};
        my $f = \%{$_[0].'::FIELDS'};

        # should be centralized in fields? perhaps
        # fields::mk_FIELDS_be_OK. Peh. As long as %{ $package . '::FIELDS' }
        # is used here anyway, it doesn't matter.
        bless $f, 'pseudohash' if (ref($f) ne 'pseudohash');

        return $f;
    }
}
else {
    *get_fields = sub {
        # Shut up a possible typo warning.
        () = \%{$_[0].'::FIELDS'};
        return \%{$_[0].'::FIELDS'};
    }
}

sub import {
    my $class = shift;

    return SUCCESS unless @_;

    # List of base classes from which we will inherit %FIELDS.
    my $fields_base;

    my $inheritor = caller(0);
    my @isa_classes;

    my @bases;
    foreach my $base (@_) {
        if ( $inheritor eq $base ) {
            warn "Class '$inheritor' tried to inherit from itself\n";
        }

        next if grep $_->isa($base), ($inheritor, @bases);

        if (has_version($base)) {
            ${$base.'::VERSION'} = '-1, set by base.pm' 
              unless defined ${$base.'::VERSION'};
        }
        else {
            my $sigdie;
            {
                local $SIG{__DIE__};
                eval "require $base";
                # Only ignore "Can't locate" errors from our eval require.
                # Other fatal errors (syntax etc) must be reported.
                die if $@ && $@ !~ /^Can't locate .*? at \(eval /;
                unless (%{"$base\::"}) {
                    require Carp;
                    local $" = " ";
                    Carp::croak(<<ERROR);
Base class package "$base" is empty.
    (Perhaps you need to 'use' the module which defines that package first,
    or make that module available in \@INC (\@INC contains: @INC).
ERROR
                }
                $sigdie = $SIG{__DIE__} || undef;
            }
            # Make sure a global $SIG{__DIE__} makes it out of the localization.
            $SIG{__DIE__} = $sigdie if defined $sigdie;
            ${$base.'::VERSION'} = "-1, set by base.pm"
              unless defined ${$base.'::VERSION'};
        }
        push @bases, $base;

        if ( has_fields($base) || has_attr($base) ) {
            # No multiple fields inheritance *suck*
            if ($fields_base) {
                require Carp;
                Carp::croak("Can't multiply inherit fields");
            } else {
                $fields_base = $base;
            }
        }
    }
    # Save this until the end so it's all or nothing if the above loop croaks.
    push @{"$inheritor\::ISA"}, @isa_classes;

    push @{"$inheritor\::ISA"}, @bases;

    if( defined $fields_base ) {
        inherit_fields($inheritor, $fields_base);
    }
}

sub inherit_fields {
    my($derived, $base) = @_;

    return SUCCESS unless $base;

    my $battr = get_attr($base);
    my $dattr = get_attr($derived);
    my $dfields = get_fields($derived);
    my $bfields = get_fields($base);

    $dattr->[0] = @$battr;

    if( keys %$dfields ) {
        warn <<"END";
$derived is inheriting from $base but already has its own fields!
This will cause problems.  Be sure you use base BEFORE declaring fields.
END

    }

    # Iterate through the base's fields adding all the non-private
    # ones to the derived class.  Hang on to the original attribute
    # (Public, Private, etc...) and add Inherited.
    # This is all too complicated to do efficiently with add_fields().
    while (my($k,$v) = each %$bfields) {
        my $fno;
        if ($fno = $dfields->{$k} and $fno != $v) {
            require Carp;
            Carp::croak ("Inherited fields can't override existing fields");
        }

        if( $battr->[$v] & PRIVATE ) {
            $dattr->[$v] = PRIVATE | INHERITED;
        }
        else {
            $dattr->[$v] = INHERITED | $battr->[$v];
            $dfields->{$k} = $v;
        }
    }

    foreach my $idx (1..$#{$battr}) {
        next if defined $dattr->[$idx];
        $dattr->[$idx] = $battr->[$idx] & INHERITED;
    }
}

1;

__END__

FILE   fb3c754b/bytes.pm  �#line 1 "/usr/share/perl/5.14/bytes.pm"
package bytes;

our $VERSION = '1.04';

$bytes::hint_bits = 0x00000008;

sub import {
    $^H |= $bytes::hint_bits;
}

sub unimport {
    $^H &= ~$bytes::hint_bits;
}

sub AUTOLOAD {
    require "bytes_heavy.pl";
    goto &$AUTOLOAD if defined &$AUTOLOAD;
    require Carp;
    Carp::croak("Undefined subroutine $AUTOLOAD called");
}

sub length (_);
sub chr (_);
sub ord (_);
sub substr ($$;$$);
sub index ($$;$);
sub rindex ($$;$);

1;
__END__

FILE   97736f7c/constant.pm  �#line 1 "/usr/share/perl/5.14/constant.pm"
package constant;
use 5.005;
use strict;
use warnings::register;

use vars qw($VERSION %declared);
$VERSION = '1.21';

#=======================================================================

# Some names are evil choices.
my %keywords = map +($_, 1), qw{ BEGIN INIT CHECK END DESTROY AUTOLOAD };
$keywords{UNITCHECK}++ if $] > 5.009;

my %forced_into_main = map +($_, 1),
    qw{ STDIN STDOUT STDERR ARGV ARGVOUT ENV INC SIG };

my %forbidden = (%keywords, %forced_into_main);

my $str_end = $] >= 5.006 ? "\\z" : "\\Z";
my $normal_constant_name = qr/^_?[^\W_0-9]\w*$str_end/;
my $tolerable = qr/^[A-Za-z_]\w*$str_end/;
my $boolean = qr/^[01]?$str_end/;

BEGIN {
    # We'd like to do use constant _CAN_PCS => $] > 5.009002
    # but that's a bit tricky before we load the constant module :-)
    # By doing this, we save 1 run time check for *every* call to import.
    no strict 'refs';
    my $const = $] > 5.009002;
    *_CAN_PCS = sub () {$const};
}

#=======================================================================
# import() - import symbols into user's namespace
#
# What we actually do is define a function in the caller's namespace
# which returns the value. The function we create will normally
# be inlined as a constant, thereby avoiding further sub calling 
# overhead.
#=======================================================================
sub import {
    my $class = shift;
    return unless @_;			# Ignore 'use constant;'
    my $constants;
    my $multiple  = ref $_[0];
    my $pkg = caller;
    my $flush_mro;
    my $symtab;

    if (_CAN_PCS) {
	no strict 'refs';
	$symtab = \%{$pkg . '::'};
    };

    if ( $multiple ) {
	if (ref $_[0] ne 'HASH') {
	    require Carp;
	    Carp::croak("Invalid reference type '".ref(shift)."' not 'HASH'");
	}
	$constants = shift;
    } else {
	unless (defined $_[0]) {
	    require Carp;
	    Carp::croak("Can't use undef as constant name");
	}
	$constants->{+shift} = undef;
    }

    foreach my $name ( keys %$constants ) {
	# Normal constant name
	if ($name =~ $normal_constant_name and !$forbidden{$name}) {
	    # Everything is okay

	# Name forced into main, but we're not in main. Fatal.
	} elsif ($forced_into_main{$name} and $pkg ne 'main') {
	    require Carp;
	    Carp::croak("Constant name '$name' is forced into main::");

	# Starts with double underscore. Fatal.
	} elsif ($name =~ /^__/) {
	    require Carp;
	    Carp::croak("Constant name '$name' begins with '__'");

	# Maybe the name is tolerable
	} elsif ($name =~ $tolerable) {
	    # Then we'll warn only if you've asked for warnings
	    if (warnings::enabled()) {
		if ($keywords{$name}) {
		    warnings::warn("Constant name '$name' is a Perl keyword");
		} elsif ($forced_into_main{$name}) {
		    warnings::warn("Constant name '$name' is " .
			"forced into package main::");
		}
	    }

	# Looks like a boolean
	# use constant FRED == fred;
	} elsif ($name =~ $boolean) {
            require Carp;
	    if (@_) {
		Carp::croak("Constant name '$name' is invalid");
	    } else {
		Carp::croak("Constant name looks like boolean value");
	    }

	} else {
	   # Must have bad characters
            require Carp;
	    Carp::croak("Constant name '$name' has invalid characters");
	}

	{
	    no strict 'refs';
	    my $full_name = "${pkg}::$name";
	    $declared{$full_name}++;
	    if ($multiple || @_ == 1) {
		my $scalar = $multiple ? $constants->{$name} : $_[0];

		# Work around perl bug #xxxxx: Sub names (actually glob
		# names in general) ignore the UTF8 flag. So we have to
		# turn it off to get the "right" symbol table entry.
		utf8::is_utf8 $name and utf8::encode $name;

		# The constant serves to optimise this entire block out on
		# 5.8 and earlier.
		if (_CAN_PCS && $symtab && !exists $symtab->{$name}) {
		    # No typeglob yet, so we can use a reference as space-
		    # efficient proxy for a constant subroutine
		    # The check in Perl_ck_rvconst knows that inlinable
		    # constants from cv_const_sv are read only. So we have to:
		    Internals::SvREADONLY($scalar, 1);
		    $symtab->{$name} = \$scalar;
		    ++$flush_mro;
		} else {
		    *$full_name = sub () { $scalar };
		}
	    } elsif (@_) {
		my @list = @_;
		*$full_name = sub () { @list };
	    } else {
		*$full_name = sub () { };
	    }
	}
    }
    # Flush the cache exactly once if we make any direct symbol table changes.
    mro::method_changed_in($pkg) if _CAN_PCS && $flush_mro;
}

1;

__END__

FILE   30c1ccc2/feature.pm  
J#line 1 "/usr/share/perl/5.14/feature.pm"
package feature;

our $VERSION = '1.20';

# (feature name) => (internal name, used in %^H)
my %feature = (
    switch          => 'feature_switch',
    say             => "feature_say",
    state           => "feature_state",
    unicode_strings => "feature_unicode",
);

# This gets set (for now) in $^H as well as in %^H,
# for runtime speed of the uc/lc/ucfirst/lcfirst functions.
# See HINT_UNI_8_BIT in perl.h.
our $hint_uni8bit = 0x00000800;

# NB. the latest bundle must be loaded by the -E switch (see toke.c)

my %feature_bundle = (
    "5.10" => [qw(switch say state)],
    "5.11" => [qw(switch say state unicode_strings)],
    "5.12" => [qw(switch say state unicode_strings)],
    "5.13" => [qw(switch say state unicode_strings)],
    "5.14" => [qw(switch say state unicode_strings)],
);

# special case
$feature_bundle{"5.9.5"} = $feature_bundle{"5.10"};

# TODO:
# - think about versioned features (use feature switch => 2)

sub import {
    my $class = shift;
    if (@_ == 0) {
	croak("No features specified");
    }
    while (@_) {
	my $name = shift(@_);
	if (substr($name, 0, 1) eq ":") {
	    my $v = substr($name, 1);
	    if (!exists $feature_bundle{$v}) {
		$v =~ s/^([0-9]+)\.([0-9]+).[0-9]+$/$1.$2/;
		if (!exists $feature_bundle{$v}) {
		    unknown_feature_bundle(substr($name, 1));
		}
	    }
	    unshift @_, @{$feature_bundle{$v}};
	    next;
	}
	if (!exists $feature{$name}) {
	    unknown_feature($name);
	}
	$^H{$feature{$name}} = 1;
        $^H |= $hint_uni8bit if $name eq 'unicode_strings';
    }
}

sub unimport {
    my $class = shift;

    # A bare C<no feature> should disable *all* features
    if (!@_) {
	delete @^H{ values(%feature) };
        $^H &= ~ $hint_uni8bit;
	return;
    }

    while (@_) {
	my $name = shift;
	if (substr($name, 0, 1) eq ":") {
	    my $v = substr($name, 1);
	    if (!exists $feature_bundle{$v}) {
		$v =~ s/^([0-9]+)\.([0-9]+).[0-9]+$/$1.$2/;
		if (!exists $feature_bundle{$v}) {
		    unknown_feature_bundle(substr($name, 1));
		}
	    }
	    unshift @_, @{$feature_bundle{$v}};
	    next;
	}
	if (!exists($feature{$name})) {
	    unknown_feature($name);
	}
	else {
	    delete $^H{$feature{$name}};
            $^H &= ~ $hint_uni8bit if $name eq 'unicode_strings';
	}
    }
}

sub unknown_feature {
    my $feature = shift;
    croak(sprintf('Feature "%s" is not supported by Perl %vd',
	    $feature, $^V));
}

sub unknown_feature_bundle {
    my $feature = shift;
    croak(sprintf('Feature bundle "%s" is not supported by Perl %vd',
	    $feature, $^V));
}

sub croak {
    require Carp;
    Carp::croak(@_);
}

1;
FILE   a68a58f2/integer.pm   �#line 1 "/usr/share/perl/5.14/integer.pm"
package integer;

our $VERSION = '1.00';

$integer::hint_bits = 0x1;

sub import {
    $^H |= $integer::hint_bits;
}

sub unimport {
    $^H &= ~$integer::hint_bits;
}

1;
FILE   58cd29b7/overload.pm  /#line 1 "/usr/share/perl/5.14/overload.pm"
package overload;

our $VERSION = '1.13';

sub nil {}

sub OVERLOAD {
  $package = shift;
  my %arg = @_;
  my ($sub, $fb);
  $ {$package . "::OVERLOAD"}{dummy}++; # Register with magic by touching.
  $fb = ${$package . "::()"}; # preserve old fallback value RT#68196
  *{$package . "::()"} = \&nil; # Make it findable via fetchmethod.
  for (keys %arg) {
    if ($_ eq 'fallback') {
      $fb = $arg{$_};
    } else {
      $sub = $arg{$_};
      if (not ref $sub and $sub !~ /::/) {
	$ {$package . "::(" . $_} = $sub;
	$sub = \&nil;
      }
      #print STDERR "Setting `$ {'package'}::\cO$_' to \\&`$sub'.\n";
      *{$package . "::(" . $_} = \&{ $sub };
    }
  }
  ${$package . "::()"} = $fb; # Make it findable too (fallback only).
}

sub import {
  $package = (caller())[0];
  # *{$package . "::OVERLOAD"} = \&OVERLOAD;
  shift;
  $package->overload::OVERLOAD(@_);
}

sub unimport {
  $package = (caller())[0];
  ${$package . "::OVERLOAD"}{dummy}++; # Upgrade the table
  shift;
  for (@_) {
    if ($_ eq 'fallback') {
      undef $ {$package . "::()"};
    } else {
      delete $ {$package . "::"}{"(" . $_};
    }
  }
}

sub Overloaded {
  my $package = shift;
  $package = ref $package if ref $package;
  $package->can('()');
}

sub ov_method {
  my $globref = shift;
  return undef unless $globref;
  my $sub = \&{*$globref};
  require Scalar::Util;
  return $sub
    if Scalar::Util::refaddr($sub) != Scalar::Util::refaddr(\&nil);
  return shift->can($ {*$globref});
}

sub OverloadedStringify {
  my $package = shift;
  $package = ref $package if ref $package;
  #$package->can('(""')
  ov_method mycan($package, '(""'), $package
    or ov_method mycan($package, '(0+'), $package
    or ov_method mycan($package, '(bool'), $package
    or ov_method mycan($package, '(nomethod'), $package;
}

sub Method {
  my $package = shift;
  if(ref $package) {
    local $@;
    local $!;
    require Scalar::Util;
    $package = Scalar::Util::blessed($package);
    return undef if !defined $package;
  }
  #my $meth = $package->can('(' . shift);
  ov_method mycan($package, '(' . shift), $package;
  #return $meth if $meth ne \&nil;
  #return $ {*{$meth}};
}

sub AddrRef {
  my $package = ref $_[0];
  return "$_[0]" unless $package;

  local $@;
  local $!;
  require Scalar::Util;
  my $class = Scalar::Util::blessed($_[0]);
  my $class_prefix = defined($class) ? "$class=" : "";
  my $type = Scalar::Util::reftype($_[0]);
  my $addr = Scalar::Util::refaddr($_[0]);
  return sprintf("%s%s(0x%x)", $class_prefix, $type, $addr);
}

*StrVal = *AddrRef;

sub mycan {				# Real can would leave stubs.
  my ($package, $meth) = @_;

  local $@;
  local $!;
  require mro;

  my $mro = mro::get_linear_isa($package);
  foreach my $p (@$mro) {
    my $fqmeth = $p . q{::} . $meth;
    return \*{$fqmeth} if defined &{$fqmeth};
  }

  return undef;
}

%constants = (
	      'integer'	  =>  0x1000, # HINT_NEW_INTEGER
	      'float'	  =>  0x2000, # HINT_NEW_FLOAT
	      'binary'	  =>  0x4000, # HINT_NEW_BINARY
	      'q'	  =>  0x8000, # HINT_NEW_STRING
	      'qr'	  => 0x10000, # HINT_NEW_RE
	     );

%ops = ( with_assign	  => "+ - * / % ** << >> x .",
	 assign		  => "+= -= *= /= %= **= <<= >>= x= .=",
	 num_comparison	  => "< <= >  >= == !=",
	 '3way_comparison'=> "<=> cmp",
	 str_comparison	  => "lt le gt ge eq ne",
	 binary		  => '& &= | |= ^ ^=',
	 unary		  => "neg ! ~",
	 mutators	  => '++ --',
	 func		  => "atan2 cos sin exp abs log sqrt int",
	 conversion	  => 'bool "" 0+ qr',
	 iterators	  => '<>',
         filetest         => "-X",
	 dereferencing	  => '${} @{} %{} &{} *{}',
	 matching	  => '~~',
	 special	  => 'nomethod fallback =');

use warnings::register;
sub constant {
  # Arguments: what, sub
  while (@_) {
    if (@_ == 1) {
        warnings::warnif ("Odd number of arguments for overload::constant");
        last;
    }
    elsif (!exists $constants {$_ [0]}) {
        warnings::warnif ("`$_[0]' is not an overloadable type");
    }
    elsif (!ref $_ [1] || "$_[1]" !~ /(^|=)CODE\(0x[0-9a-f]+\)$/) {
        # Can't use C<ref $_[1] eq "CODE"> above as code references can be
        # blessed, and C<ref> would return the package the ref is blessed into.
        if (warnings::enabled) {
            $_ [1] = "undef" unless defined $_ [1];
            warnings::warn ("`$_[1]' is not a code reference");
        }
    }
    else {
        $^H{$_[0]} = $_[1];
        $^H |= $constants{$_[0]};
    }
    shift, shift;
  }
}

sub remove_constant {
  # Arguments: what, sub
  while (@_) {
    delete $^H{$_[0]};
    $^H &= ~ $constants{$_[0]};
    shift, shift;
  }
}

1;

__END__

FILE   b3a7425d/strict.pm  �#line 1 "/usr/share/perl/5.14/strict.pm"
package strict;

$strict::VERSION = "1.04";

# Verify that we're called correctly so that strictures will work.
unless ( __FILE__ =~ /(^|[\/\\])\Q${\__PACKAGE__}\E\.pmc?$/ ) {
    # Can't use Carp, since Carp uses us!
    my (undef, $f, $l) = caller;
    die("Incorrect use of pragma '${\__PACKAGE__}' at $f line $l.\n");
}

my %bitmask = (
refs => 0x00000002,
subs => 0x00000200,
vars => 0x00000400
);

sub bits {
    my $bits = 0;
    my @wrong;
    foreach my $s (@_) {
	push @wrong, $s unless exists $bitmask{$s};
        $bits |= $bitmask{$s} || 0;
    }
    if (@wrong) {
        require Carp;
        Carp::croak("Unknown 'strict' tag(s) '@wrong'");
    }
    $bits;
}

my $default_bits = bits(qw(refs subs vars));

sub import {
    shift;
    $^H |= @_ ? bits(@_) : $default_bits;
}

sub unimport {
    shift;
    $^H &= ~ (@_ ? bits(@_) : $default_bits);
}

1;
__END__

FILE   3738f93b/utf8.pm  �#line 1 "/usr/share/perl/5.14/utf8.pm"
package utf8;

$utf8::hint_bits = 0x00800000;

our $VERSION = '1.09';

sub import {
    $^H |= $utf8::hint_bits;
    $enc{caller()} = $_[1] if $_[1];
}

sub unimport {
    $^H &= ~$utf8::hint_bits;
}

sub AUTOLOAD {
    require "utf8_heavy.pl";
    goto &$AUTOLOAD if defined &$AUTOLOAD;
    require Carp;
    Carp::croak("Undefined subroutine $AUTOLOAD called");
}

1;
__END__

FILE   cdf3441b/vars.pm  �#line 1 "/usr/share/perl/5.14/vars.pm"
package vars;

use 5.006;

our $VERSION = '1.02';

use warnings::register;
use strict qw(vars subs);

sub import {
    my $callpack = caller;
    my (undef, @imports) = @_;
    my ($sym, $ch);
    foreach (@imports) {
        if (($ch, $sym) = /^([\$\@\%\*\&])(.+)/) {
	    if ($sym =~ /\W/) {
		# time for a more-detailed check-up
		if ($sym =~ /^\w+[[{].*[]}]$/) {
		    require Carp;
		    Carp::croak("Can't declare individual elements of hash or array");
		} elsif (warnings::enabled() and length($sym) == 1 and $sym !~ tr/a-zA-Z//) {
		    warnings::warn("No need to declare built-in vars");
		} elsif  (($^H &= strict::bits('vars'))) {
		    require Carp;
		    Carp::croak("'$_' is not a valid variable name under strict vars");
		}
	    }
	    $sym = "${callpack}::$sym" unless $sym =~ /::/;
	    *$sym =
		(  $ch eq "\$" ? \$$sym
		 : $ch eq "\@" ? \@$sym
		 : $ch eq "\%" ? \%$sym
		 : $ch eq "\*" ? \*$sym
		 : $ch eq "\&" ? \&$sym 
		 : do {
		     require Carp;
		     Carp::croak("'$_' is not a valid variable name");
		 });
	} else {
	    require Carp;
	    Carp::croak("'$_' is not a valid variable name");
	}
    }
};

1;
__END__

FILE   2312a55e/warnings.pm  :�#line 1 "/usr/share/perl/5.14/warnings.pm"
# -*- buffer-read-only: t -*-
# !!!!!!!   DO NOT EDIT THIS FILE   !!!!!!!
# This file is built by regen/warnings.pl.
# Any changes made here will be lost!

package warnings;

our $VERSION = '1.12';

# Verify that we're called correctly so that warnings will work.
# see also strict.pm.
unless ( __FILE__ =~ /(^|[\/\\])\Q${\__PACKAGE__}\E\.pmc?$/ ) {
    my (undef, $f, $l) = caller;
    die("Incorrect use of pragma '${\__PACKAGE__}' at $f line $l.\n");
}

our %Offsets = (

    # Warnings Categories added in Perl 5.008

    'all'		=> 0,
    'closure'		=> 2,
    'deprecated'	=> 4,
    'exiting'		=> 6,
    'glob'		=> 8,
    'io'		=> 10,
    'closed'		=> 12,
    'exec'		=> 14,
    'layer'		=> 16,
    'newline'		=> 18,
    'pipe'		=> 20,
    'unopened'		=> 22,
    'misc'		=> 24,
    'numeric'		=> 26,
    'once'		=> 28,
    'overflow'		=> 30,
    'pack'		=> 32,
    'portable'		=> 34,
    'recursion'		=> 36,
    'redefine'		=> 38,
    'regexp'		=> 40,
    'severe'		=> 42,
    'debugging'		=> 44,
    'inplace'		=> 46,
    'internal'		=> 48,
    'malloc'		=> 50,
    'signal'		=> 52,
    'substr'		=> 54,
    'syntax'		=> 56,
    'ambiguous'		=> 58,
    'bareword'		=> 60,
    'digit'		=> 62,
    'parenthesis'	=> 64,
    'precedence'	=> 66,
    'printf'		=> 68,
    'prototype'		=> 70,
    'qw'		=> 72,
    'reserved'		=> 74,
    'semicolon'		=> 76,
    'taint'		=> 78,
    'threads'		=> 80,
    'uninitialized'	=> 82,
    'unpack'		=> 84,
    'untie'		=> 86,
    'utf8'		=> 88,
    'void'		=> 90,

    # Warnings Categories added in Perl 5.011

    'imprecision'	=> 92,
    'illegalproto'	=> 94,

    # Warnings Categories added in Perl 5.013

    'non_unicode'	=> 96,
    'nonchar'		=> 98,
    'surrogate'		=> 100,
  );

our %Bits = (
    'all'		=> "\x55\x55\x55\x55\x55\x55\x55\x55\x55\x55\x55\x55\x15", # [0..50]
    'ambiguous'		=> "\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00", # [29]
    'bareword'		=> "\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00", # [30]
    'closed'		=> "\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [6]
    'closure'		=> "\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [1]
    'debugging'		=> "\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00", # [22]
    'deprecated'	=> "\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [2]
    'digit'		=> "\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00", # [31]
    'exec'		=> "\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [7]
    'exiting'		=> "\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [3]
    'glob'		=> "\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [4]
    'illegalproto'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00", # [47]
    'imprecision'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00", # [46]
    'inplace'		=> "\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00", # [23]
    'internal'		=> "\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00", # [24]
    'io'		=> "\x00\x54\x55\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [5..11]
    'layer'		=> "\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [8]
    'malloc'		=> "\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00", # [25]
    'misc'		=> "\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [12]
    'newline'		=> "\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [9]
    'non_unicode'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01", # [48]
    'nonchar'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04", # [49]
    'numeric'		=> "\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [13]
    'once'		=> "\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [14]
    'overflow'		=> "\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [15]
    'pack'		=> "\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00", # [16]
    'parenthesis'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00", # [32]
    'pipe'		=> "\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [10]
    'portable'		=> "\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00", # [17]
    'precedence'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00", # [33]
    'printf'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00", # [34]
    'prototype'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00", # [35]
    'qw'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00", # [36]
    'recursion'		=> "\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00", # [18]
    'redefine'		=> "\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00", # [19]
    'regexp'		=> "\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00", # [20]
    'reserved'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00", # [37]
    'semicolon'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00", # [38]
    'severe'		=> "\x00\x00\x00\x00\x00\x54\x05\x00\x00\x00\x00\x00\x00", # [21..25]
    'signal'		=> "\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00", # [26]
    'substr'		=> "\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00", # [27]
    'surrogate'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10", # [50]
    'syntax'		=> "\x00\x00\x00\x00\x00\x00\x00\x55\x55\x15\x00\x40\x00", # [28..38,47]
    'taint'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00", # [39]
    'threads'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00", # [40]
    'uninitialized'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00", # [41]
    'unopened'		=> "\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [11]
    'unpack'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00", # [42]
    'untie'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00", # [43]
    'utf8'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x15", # [44,48..50]
    'void'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00", # [45]
  );

our %DeadBits = (
    'all'		=> "\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\x2a", # [0..50]
    'ambiguous'		=> "\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00", # [29]
    'bareword'		=> "\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00", # [30]
    'closed'		=> "\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [6]
    'closure'		=> "\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [1]
    'debugging'		=> "\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00", # [22]
    'deprecated'	=> "\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [2]
    'digit'		=> "\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00", # [31]
    'exec'		=> "\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [7]
    'exiting'		=> "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [3]
    'glob'		=> "\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [4]
    'illegalproto'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00", # [47]
    'imprecision'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00", # [46]
    'inplace'		=> "\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00", # [23]
    'internal'		=> "\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00", # [24]
    'io'		=> "\x00\xa8\xaa\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [5..11]
    'layer'		=> "\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [8]
    'malloc'		=> "\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00", # [25]
    'misc'		=> "\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [12]
    'newline'		=> "\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [9]
    'non_unicode'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02", # [48]
    'nonchar'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08", # [49]
    'numeric'		=> "\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [13]
    'once'		=> "\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [14]
    'overflow'		=> "\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [15]
    'pack'		=> "\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00", # [16]
    'parenthesis'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00", # [32]
    'pipe'		=> "\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [10]
    'portable'		=> "\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00", # [17]
    'precedence'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00", # [33]
    'printf'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00", # [34]
    'prototype'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00", # [35]
    'qw'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00", # [36]
    'recursion'		=> "\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00", # [18]
    'redefine'		=> "\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00", # [19]
    'regexp'		=> "\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00", # [20]
    'reserved'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00", # [37]
    'semicolon'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00", # [38]
    'severe'		=> "\x00\x00\x00\x00\x00\xa8\x0a\x00\x00\x00\x00\x00\x00", # [21..25]
    'signal'		=> "\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00", # [26]
    'substr'		=> "\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00", # [27]
    'surrogate'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20", # [50]
    'syntax'		=> "\x00\x00\x00\x00\x00\x00\x00\xaa\xaa\x2a\x00\x80\x00", # [28..38,47]
    'taint'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00", # [39]
    'threads'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00", # [40]
    'uninitialized'	=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00", # [41]
    'unopened'		=> "\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", # [11]
    'unpack'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00", # [42]
    'untie'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00", # [43]
    'utf8'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x2a", # [44,48..50]
    'void'		=> "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00", # [45]
  );

$NONE     = "\0\0\0\0\0\0\0\0\0\0\0\0\0";
$LAST_BIT = 102 ;
$BYTES    = 13 ;

$All = "" ; vec($All, $Offsets{'all'}, 2) = 3 ;

sub Croaker
{
    require Carp; # this initializes %CarpInternal
    local $Carp::CarpInternal{'warnings'};
    delete $Carp::CarpInternal{'warnings'};
    Carp::croak(@_);
}

sub _bits {
    my $mask = shift ;
    my $catmask ;
    my $fatal = 0 ;
    my $no_fatal = 0 ;

    foreach my $word ( @_ ) {
	if ($word eq 'FATAL') {
	    $fatal = 1;
	    $no_fatal = 0;
	}
	elsif ($word eq 'NONFATAL') {
	    $fatal = 0;
	    $no_fatal = 1;
	}
	elsif ($catmask = $Bits{$word}) {
	    $mask |= $catmask ;
	    $mask |= $DeadBits{$word} if $fatal ;
	    $mask &= ~($DeadBits{$word}|$All) if $no_fatal ;
	}
	else
          { Croaker("Unknown warnings category '$word'")}
    }

    return $mask ;
}

sub bits
{
    # called from B::Deparse.pm
    push @_, 'all' unless @_ ;
    return _bits(undef, @_) ;
}

sub import 
{
    shift;

    my $mask = ${^WARNING_BITS} ;

    if (vec($mask, $Offsets{'all'}, 1)) {
        $mask |= $Bits{'all'} ;
        $mask |= $DeadBits{'all'} if vec($mask, $Offsets{'all'}+1, 1);
    }
    
    # Empty @_ is equivalent to @_ = 'all' ;
    ${^WARNING_BITS} = @_ ? _bits($mask, @_) : $mask | $Bits{all} ;
}

sub unimport 
{
    shift;

    my $catmask ;
    my $mask = ${^WARNING_BITS} ;

    if (vec($mask, $Offsets{'all'}, 1)) {
        $mask |= $Bits{'all'} ;
        $mask |= $DeadBits{'all'} if vec($mask, $Offsets{'all'}+1, 1);
    }

    push @_, 'all' unless @_;

    foreach my $word ( @_ ) {
	if ($word eq 'FATAL') {
	    next; 
	}
	elsif ($catmask = $Bits{$word}) {
	    $mask &= ~($catmask | $DeadBits{$word} | $All);
	}
	else
          { Croaker("Unknown warnings category '$word'")}
    }

    ${^WARNING_BITS} = $mask ;
}

my %builtin_type; @builtin_type{qw(SCALAR ARRAY HASH CODE REF GLOB LVALUE Regexp)} = ();

sub MESSAGE () { 4 };
sub FATAL () { 2 };
sub NORMAL () { 1 };

sub __chk
{
    my $category ;
    my $offset ;
    my $isobj = 0 ;
    my $wanted = shift;
    my $has_message = $wanted & MESSAGE;

    unless (@_ == 1 || @_ == ($has_message ? 2 : 0)) {
	my $sub = (caller 1)[3];
	my $syntax = $has_message ? "[category,] 'message'" : '[category]';
	Croaker("Usage: $sub($syntax)");
    }

    my $message = pop if $has_message;

    if (@_) {
        # check the category supplied.
        $category = shift ;
        if (my $type = ref $category) {
            Croaker("not an object")
                if exists $builtin_type{$type};
	    $category = $type;
            $isobj = 1 ;
        }
        $offset = $Offsets{$category};
        Croaker("Unknown warnings category '$category'")
	    unless defined $offset;
    }
    else {
        $category = (caller(1))[0] ;
        $offset = $Offsets{$category};
        Croaker("package '$category' not registered for warnings")
	    unless defined $offset ;
    }

    my $i;

    if ($isobj) {
        my $pkg;
        $i = 2;
        while (do { { package DB; $pkg = (caller($i++))[0] } } ) {
            last unless @DB::args && $DB::args[0] =~ /^$category=/ ;
        }
	$i -= 2 ;
    }
    else {
        $i = _error_loc(); # see where Carp will allocate the error
    }

    # Defaulting this to 0 reduces complexity in code paths below.
    my $callers_bitmask = (caller($i))[9] || 0 ;

    my @results;
    foreach my $type (FATAL, NORMAL) {
	next unless $wanted & $type;

	push @results, (vec($callers_bitmask, $offset + $type - 1, 1) ||
			vec($callers_bitmask, $Offsets{'all'} + $type - 1, 1));
    }

    # &enabled and &fatal_enabled
    return $results[0] unless $has_message;

    # &warnif, and the category is neither enabled as warning nor as fatal
    return if $wanted == (NORMAL | FATAL | MESSAGE)
	&& !($results[0] || $results[1]);

    require Carp;
    Carp::croak($message) if $results[0];
    # will always get here for &warn. will only get here for &warnif if the
    # category is enabled
    Carp::carp($message);
}

sub _mkMask
{
    my ($bit) = @_;
    my $mask = "";

    vec($mask, $bit, 1) = 1;
    return $mask;
}

sub register_categories
{
    my @names = @_;

    for my $name (@names) {
	if (! defined $Bits{$name}) {
	    $Bits{$name}     = _mkMask($LAST_BIT);
	    vec($Bits{'all'}, $LAST_BIT, 1) = 1;
	    $Offsets{$name}  = $LAST_BIT ++;
	    foreach my $k (keys %Bits) {
		vec($Bits{$k}, $LAST_BIT, 1) = 0;
	    }
	    $DeadBits{$name} = _mkMask($LAST_BIT);
	    vec($DeadBits{'all'}, $LAST_BIT++, 1) = 1;
	}
    }
}

sub _error_loc {
    require Carp;
    goto &Carp::short_error_loc; # don't introduce another stack frame
}

sub enabled
{
    return __chk(NORMAL, @_);
}

sub fatal_enabled
{
    return __chk(FATAL, @_);
}

sub warn
{
    return __chk(FATAL | MESSAGE, @_);
}

sub warnif
{
    return __chk(NORMAL | FATAL | MESSAGE, @_);
}

# These are not part of any public interface, so we can delete them to save
# space.
delete $warnings::{$_} foreach qw(NORMAL FATAL MESSAGE);

1;

# ex: set ro:
FILE   6e162436/warnings/register.pm  #line 1 "/usr/share/perl/5.14/warnings/register.pm"
package warnings::register;

our $VERSION = '1.02';

require warnings;

# left here as cruft in case other users were using this undocumented routine
# -- rjbs, 2010-09-08
sub mkMask
{
    my ($bit) = @_;
    my $mask = "";

    vec($mask, $bit, 1) = 1;
    return $mask;
}

sub import
{
    shift;
    my @categories = @_;

    my $package = (caller(0))[0];
    warnings::register_categories($package);

    warnings::register_categories($package . "::$_") for @categories;
}

1;
FILE   0a893305/Archive/Zip.pm  C#line 1 "/usr/share/perl5/Archive/Zip.pm"
package Archive::Zip;

use strict;
BEGIN {
    require 5.003_96;
}
use UNIVERSAL           ();
use Carp                ();
use Cwd                 ();
use IO::File            ();
use IO::Seekable        ();
use Compress::Raw::Zlib ();
use File::Spec          ();
use File::Temp          ();
use FileHandle          ();

use vars qw( $VERSION @ISA );
BEGIN {
    $VERSION = '1.30';

    require Exporter;
    @ISA = qw( Exporter );
}

use vars qw( $ChunkSize $ErrorHandler );
BEGIN {
    # This is the size we'll try to read, write, and (de)compress.
    # You could set it to something different if you had lots of memory
    # and needed more speed.
    $ChunkSize ||= 32768;

    $ErrorHandler = \&Carp::carp;
}

# BEGIN block is necessary here so that other modules can use the constants.
use vars qw( @EXPORT_OK %EXPORT_TAGS );
BEGIN {
    @EXPORT_OK   = ('computeCRC32');
    %EXPORT_TAGS = (
        CONSTANTS => [ qw(
            FA_MSDOS
            FA_UNIX
            GPBF_ENCRYPTED_MASK
            GPBF_DEFLATING_COMPRESSION_MASK
            GPBF_HAS_DATA_DESCRIPTOR_MASK
            COMPRESSION_STORED
            COMPRESSION_DEFLATED
            COMPRESSION_LEVEL_NONE
            COMPRESSION_LEVEL_DEFAULT
            COMPRESSION_LEVEL_FASTEST
            COMPRESSION_LEVEL_BEST_COMPRESSION
            IFA_TEXT_FILE_MASK
            IFA_TEXT_FILE
            IFA_BINARY_FILE
            ) ],

        MISC_CONSTANTS => [ qw(
            FA_AMIGA
            FA_VAX_VMS
            FA_VM_CMS
            FA_ATARI_ST
            FA_OS2_HPFS
            FA_MACINTOSH
            FA_Z_SYSTEM
            FA_CPM
            FA_TOPS20
            FA_WINDOWS_NTFS
            FA_QDOS
            FA_ACORN
            FA_VFAT
            FA_MVS
            FA_BEOS
            FA_TANDEM
            FA_THEOS
            GPBF_IMPLODING_8K_SLIDING_DICTIONARY_MASK
            GPBF_IMPLODING_3_SHANNON_FANO_TREES_MASK
            GPBF_IS_COMPRESSED_PATCHED_DATA_MASK
            COMPRESSION_SHRUNK
            DEFLATING_COMPRESSION_NORMAL
            DEFLATING_COMPRESSION_MAXIMUM
            DEFLATING_COMPRESSION_FAST
            DEFLATING_COMPRESSION_SUPER_FAST
            COMPRESSION_REDUCED_1
            COMPRESSION_REDUCED_2
            COMPRESSION_REDUCED_3
            COMPRESSION_REDUCED_4
            COMPRESSION_IMPLODED
            COMPRESSION_TOKENIZED
            COMPRESSION_DEFLATED_ENHANCED
            COMPRESSION_PKWARE_DATA_COMPRESSION_LIBRARY_IMPLODED
            ) ],

        ERROR_CODES => [ qw(
            AZ_OK
            AZ_STREAM_END
            AZ_ERROR
            AZ_FORMAT_ERROR
            AZ_IO_ERROR
            ) ],

        # For Internal Use Only
        PKZIP_CONSTANTS => [ qw(
            SIGNATURE_FORMAT
            SIGNATURE_LENGTH
            LOCAL_FILE_HEADER_SIGNATURE
            LOCAL_FILE_HEADER_FORMAT
            LOCAL_FILE_HEADER_LENGTH
            CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE
            DATA_DESCRIPTOR_FORMAT
            DATA_DESCRIPTOR_LENGTH
            DATA_DESCRIPTOR_SIGNATURE
            DATA_DESCRIPTOR_FORMAT_NO_SIG
            DATA_DESCRIPTOR_LENGTH_NO_SIG
            CENTRAL_DIRECTORY_FILE_HEADER_FORMAT
            CENTRAL_DIRECTORY_FILE_HEADER_LENGTH
            END_OF_CENTRAL_DIRECTORY_SIGNATURE
            END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING
            END_OF_CENTRAL_DIRECTORY_FORMAT
            END_OF_CENTRAL_DIRECTORY_LENGTH
            ) ],

        # For Internal Use Only
        UTILITY_METHODS => [ qw(
            _error
            _printError
            _ioError
            _formatError
            _subclassResponsibility
            _binmode
            _isSeekable
            _newFileHandle
            _readSignature
            _asZipDirName
            ) ],
    );

    # Add all the constant names and error code names to @EXPORT_OK
    Exporter::export_ok_tags( qw(
        CONSTANTS
        ERROR_CODES
        PKZIP_CONSTANTS
        UTILITY_METHODS
        MISC_CONSTANTS
        ) );

}

# Error codes
use constant AZ_OK           => 0;
use constant AZ_STREAM_END   => 1;
use constant AZ_ERROR        => 2;
use constant AZ_FORMAT_ERROR => 3;
use constant AZ_IO_ERROR     => 4;

# File types
# Values of Archive::Zip::Member->fileAttributeFormat()

use constant FA_MSDOS        => 0;
use constant FA_AMIGA        => 1;
use constant FA_VAX_VMS      => 2;
use constant FA_UNIX         => 3;
use constant FA_VM_CMS       => 4;
use constant FA_ATARI_ST     => 5;
use constant FA_OS2_HPFS     => 6;
use constant FA_MACINTOSH    => 7;
use constant FA_Z_SYSTEM     => 8;
use constant FA_CPM          => 9;
use constant FA_TOPS20       => 10;
use constant FA_WINDOWS_NTFS => 11;
use constant FA_QDOS         => 12;
use constant FA_ACORN        => 13;
use constant FA_VFAT         => 14;
use constant FA_MVS          => 15;
use constant FA_BEOS         => 16;
use constant FA_TANDEM       => 17;
use constant FA_THEOS        => 18;

# general-purpose bit flag masks
# Found in Archive::Zip::Member->bitFlag()

use constant GPBF_ENCRYPTED_MASK             => 1 << 0;
use constant GPBF_DEFLATING_COMPRESSION_MASK => 3 << 1;
use constant GPBF_HAS_DATA_DESCRIPTOR_MASK   => 1 << 3;

# deflating compression types, if compressionMethod == COMPRESSION_DEFLATED
# ( Archive::Zip::Member->bitFlag() & GPBF_DEFLATING_COMPRESSION_MASK )

use constant DEFLATING_COMPRESSION_NORMAL     => 0 << 1;
use constant DEFLATING_COMPRESSION_MAXIMUM    => 1 << 1;
use constant DEFLATING_COMPRESSION_FAST       => 2 << 1;
use constant DEFLATING_COMPRESSION_SUPER_FAST => 3 << 1;

# compression method

# these two are the only ones supported in this module
use constant COMPRESSION_STORED                 => 0; # file is stored (no compression)
use constant COMPRESSION_DEFLATED               => 8; # file is Deflated
use constant COMPRESSION_LEVEL_NONE             => 0;
use constant COMPRESSION_LEVEL_DEFAULT          => -1;
use constant COMPRESSION_LEVEL_FASTEST          => 1;
use constant COMPRESSION_LEVEL_BEST_COMPRESSION => 9;

# internal file attribute bits
# Found in Archive::Zip::Member::internalFileAttributes()

use constant IFA_TEXT_FILE_MASK => 1;
use constant IFA_TEXT_FILE      => 1;
use constant IFA_BINARY_FILE    => 0;

# PKZIP file format miscellaneous constants (for internal use only)
use constant SIGNATURE_FORMAT   => "V";
use constant SIGNATURE_LENGTH   => 4;

# these lengths are without the signature.
use constant LOCAL_FILE_HEADER_SIGNATURE   => 0x04034b50;
use constant LOCAL_FILE_HEADER_FORMAT      => "v3 V4 v2";
use constant LOCAL_FILE_HEADER_LENGTH      => 26;

# PKZIP docs don't mention the signature, but Info-Zip writes it.
use constant DATA_DESCRIPTOR_SIGNATURE     => 0x08074b50;
use constant DATA_DESCRIPTOR_FORMAT        => "V3";
use constant DATA_DESCRIPTOR_LENGTH        => 12;

# but the signature is apparently optional.
use constant DATA_DESCRIPTOR_FORMAT_NO_SIG => "V2";
use constant DATA_DESCRIPTOR_LENGTH_NO_SIG => 8;

use constant CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE  => 0x02014b50;
use constant CENTRAL_DIRECTORY_FILE_HEADER_FORMAT     => "C2 v3 V4 v5 V2";
use constant CENTRAL_DIRECTORY_FILE_HEADER_LENGTH     => 42;

use constant END_OF_CENTRAL_DIRECTORY_SIGNATURE        => 0x06054b50;
use constant END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING =>
    pack( "V", END_OF_CENTRAL_DIRECTORY_SIGNATURE );
use constant END_OF_CENTRAL_DIRECTORY_FORMAT           => "v4 V2 v";
use constant END_OF_CENTRAL_DIRECTORY_LENGTH           => 18;

use constant GPBF_IMPLODING_8K_SLIDING_DICTIONARY_MASK => 1 << 1;
use constant GPBF_IMPLODING_3_SHANNON_FANO_TREES_MASK  => 1 << 2;
use constant GPBF_IS_COMPRESSED_PATCHED_DATA_MASK      => 1 << 5;

# the rest of these are not supported in this module
use constant COMPRESSION_SHRUNK    => 1;    # file is Shrunk
use constant COMPRESSION_REDUCED_1 => 2;    # file is Reduced CF=1
use constant COMPRESSION_REDUCED_2 => 3;    # file is Reduced CF=2
use constant COMPRESSION_REDUCED_3 => 4;    # file is Reduced CF=3
use constant COMPRESSION_REDUCED_4 => 5;    # file is Reduced CF=4
use constant COMPRESSION_IMPLODED  => 6;    # file is Imploded
use constant COMPRESSION_TOKENIZED => 7;    # reserved for Tokenizing compr.
use constant COMPRESSION_DEFLATED_ENHANCED => 9;   # reserved for enh. Deflating
use constant COMPRESSION_PKWARE_DATA_COMPRESSION_LIBRARY_IMPLODED => 10;

# Load the various required classes
require Archive::Zip::Archive;
require Archive::Zip::Member;
require Archive::Zip::FileMember;
require Archive::Zip::DirectoryMember;
require Archive::Zip::ZipFileMember;
require Archive::Zip::NewFileMember;
require Archive::Zip::StringMember;

use constant ZIPARCHIVECLASS => 'Archive::Zip::Archive';
use constant ZIPMEMBERCLASS  => 'Archive::Zip::Member';

# Convenience functions

sub _ISA ($$) {
    # Can't rely on Scalar::Util, so use the next best way
    local $@;
    !! eval { ref $_[0] and $_[0]->isa($_[1]) };
}

sub _CAN ($$) {
    local $@;
    !! eval { ref $_[0] and $_[0]->can($_[1]) };
}





#####################################################################
# Methods

sub new {
    my $class = shift;
    return $class->ZIPARCHIVECLASS->new(@_);
}

sub computeCRC32 {
    my ( $data, $crc );

    if ( ref( $_[0] ) eq 'HASH' ) {
        $data = $_[0]->{string};
        $crc  = $_[0]->{checksum};
    }
    else {
        $data = shift;
        $data = shift if ref($data);
        $crc  = shift;
    }

	return Compress::Raw::Zlib::crc32( $data, $crc );
}

# Report or change chunk size used for reading and writing.
# Also sets Zlib's default buffer size (eventually).
sub setChunkSize {
    shift if ref( $_[0] ) eq 'Archive::Zip::Archive';
    my $chunkSize = ( ref( $_[0] ) eq 'HASH' ) ? shift->{chunkSize} : shift;
    my $oldChunkSize = $Archive::Zip::ChunkSize;
    $Archive::Zip::ChunkSize = $chunkSize if ($chunkSize);
    return $oldChunkSize;
}

sub chunkSize {
    return $Archive::Zip::ChunkSize;
}

sub setErrorHandler {
    my $errorHandler = ( ref( $_[0] ) eq 'HASH' ) ? shift->{subroutine} : shift;
    $errorHandler = \&Carp::carp unless defined($errorHandler);
    my $oldErrorHandler = $Archive::Zip::ErrorHandler;
    $Archive::Zip::ErrorHandler = $errorHandler;
    return $oldErrorHandler;
}





######################################################################
# Private utility functions (not methods).

sub _printError {
    my $string = join ( ' ', @_, "\n" );
    my $oldCarpLevel = $Carp::CarpLevel;
    $Carp::CarpLevel += 2;
    &{$ErrorHandler} ($string);
    $Carp::CarpLevel = $oldCarpLevel;
}

# This is called on format errors.
sub _formatError {
    shift if ref( $_[0] );
    _printError( 'format error:', @_ );
    return AZ_FORMAT_ERROR;
}

# This is called on IO errors.
sub _ioError {
    shift if ref( $_[0] );
    _printError( 'IO error:', @_, ':', $! );
    return AZ_IO_ERROR;
}

# This is called on generic errors.
sub _error {
    shift if ref( $_[0] );
    _printError( 'error:', @_ );
    return AZ_ERROR;
}

# Called when a subclass should have implemented
# something but didn't
sub _subclassResponsibility {
    Carp::croak("subclass Responsibility\n");
}

# Try to set the given file handle or object into binary mode.
sub _binmode {
    my $fh = shift;
    return _CAN( $fh, 'binmode' ) ? $fh->binmode() : binmode($fh);
}

# Attempt to guess whether file handle is seekable.
# Because of problems with Windows, this only returns true when
# the file handle is a real file.  
sub _isSeekable {
    my $fh = shift;
    return 0 unless ref $fh;
    if ( _ISA($fh, 'IO::Scalar') ) {
        # IO::Scalar objects are brokenly-seekable
        return 0;
    }
    if ( _ISA($fh, 'IO::String') ) {
        return 1;
    }
    if ( _ISA($fh, 'IO::Seekable') ) {
        # Unfortunately, some things like FileHandle objects
        # return true for Seekable, but AREN'T!!!!!
        if ( _ISA($fh, 'FileHandle') ) {
            return 0;
        } else {
            return 1;
        }
    }
    if ( _CAN($fh, 'stat') ) {
        return -f $fh;
    }
    return (
        _CAN($fh, 'seek') and _CAN($fh, 'tell')
        ) ? 1 : 0;
}

# Print to the filehandle, while making sure the pesky Perl special global 
# variables don't interfere.
sub _print
{
    my ($self, $fh, @data) = @_;

    local $\;

    return $fh->print(@data);
}

# Return an opened IO::Handle
# my ( $status, fh ) = _newFileHandle( 'fileName', 'w' );
# Can take a filename, file handle, or ref to GLOB
# Or, if given something that is a ref but not an IO::Handle,
# passes back the same thing.
sub _newFileHandle {
    my $fd     = shift;
    my $status = 1;
    my $handle;

    if ( ref($fd) ) {
        if ( _ISA($fd, 'IO::Scalar') or _ISA($fd, 'IO::String') ) {
            $handle = $fd;
        } elsif ( _ISA($fd, 'IO::Handle') or ref($fd) eq 'GLOB' ) {
            $handle = IO::File->new;
            $status = $handle->fdopen( $fd, @_ );
        } else {
            $handle = $fd;
        }
    } else {
        $handle = IO::File->new;
        $status = $handle->open( $fd, @_ );
    }

    return ( $status, $handle );
}

# Returns next signature from given file handle, leaves
# file handle positioned afterwards.
# In list context, returns ($status, $signature)
# ( $status, $signature) = _readSignature( $fh, $fileName );

sub _readSignature {
    my $fh                = shift;
    my $fileName          = shift;
    my $expectedSignature = shift;    # optional

    my $signatureData;
    my $bytesRead = $fh->read( $signatureData, SIGNATURE_LENGTH );
    if ( $bytesRead != SIGNATURE_LENGTH ) {
        return _ioError("reading header signature");
    }
    my $signature = unpack( SIGNATURE_FORMAT, $signatureData );
    my $status    = AZ_OK;

    # compare with expected signature, if any, or any known signature.
    if ( ( defined($expectedSignature) && $signature != $expectedSignature )
        || ( !defined($expectedSignature)
            && $signature != CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE
            && $signature != LOCAL_FILE_HEADER_SIGNATURE
            && $signature != END_OF_CENTRAL_DIRECTORY_SIGNATURE
            && $signature != DATA_DESCRIPTOR_SIGNATURE ) )
    {
        my $errmsg = sprintf( "bad signature: 0x%08x", $signature );
        if ( _isSeekable($fh) )
        {
            $errmsg .=
              sprintf( " at offset %d", $fh->tell() - SIGNATURE_LENGTH );
        }

        $status = _formatError("$errmsg in file $fileName");
    }

    return ( $status, $signature );
}

# Utility method to make and open a temp file.
# Will create $temp_dir if it doesn't exist.
# Returns file handle and name:
#
# my ($fh, $name) = Archive::Zip::tempFile();
# my ($fh, $name) = Archive::Zip::tempFile('mytempdir');
#

sub tempFile {
    my $dir = ( ref( $_[0] ) eq 'HASH' ) ? shift->{tempDir} : shift;
    my ( $fh, $filename ) = File::Temp::tempfile(
        SUFFIX => '.zip',
        UNLINK => 0,        # we will delete it!
        $dir ? ( DIR => $dir ) : ()
    );
    return ( undef, undef ) unless $fh;
    my ( $status, $newfh ) = _newFileHandle( $fh, 'w+' );
    return ( $newfh, $filename );
}

# Return the normalized directory name as used in a zip file (path
# separators become slashes, etc.). 
# Will translate internal slashes in path components (i.e. on Macs) to
# underscores.  Discards volume names.
# When $forceDir is set, returns paths with trailing slashes (or arrays
# with trailing blank members).
#
# If third argument is a reference, returns volume information there.
#
# input         output
# .             ('.')   '.'
# ./a           ('a')   a
# ./a/b         ('a','b')   a/b
# ./a/b/        ('a','b')   a/b
# a/b/          ('a','b')   a/b
# /a/b/         ('','a','b')    /a/b
# c:\a\b\c.doc  ('','a','b','c.doc')    /a/b/c.doc      # on Windoze
# "i/o maps:whatever"   ('i_o maps', 'whatever')  "i_o maps/whatever"   # on Macs
sub _asZipDirName    
{
    my $name      = shift;
    my $forceDir  = shift;
    my $volReturn = shift;
    my ( $volume, $directories, $file ) =
      File::Spec->splitpath( File::Spec->canonpath($name), $forceDir );
    $$volReturn = $volume if ( ref($volReturn) );
    my @dirs = map { $_ =~ s{/}{_}g; $_ } File::Spec->splitdir($directories);
    if ( @dirs > 0 ) { pop (@dirs) unless $dirs[-1] }   # remove empty component
    push ( @dirs, defined($file) ? $file : '' );
    #return wantarray ? @dirs : join ( '/', @dirs );
    return join ( '/', @dirs );
}

# Return an absolute local name for a zip name.
# Assume a directory if zip name has trailing slash.
# Takes an optional volume name in FS format (like 'a:').
#
sub _asLocalName    
{
    my $name   = shift;    # zip format
    my $volume = shift;
    $volume = '' unless defined($volume);    # local FS format

    my @paths = split ( /\//, $name );
    my $filename = pop (@paths);
    $filename = '' unless defined($filename);
    my $localDirs = @paths ? File::Spec->catdir(@paths) : '';
    my $localName = File::Spec->catpath( $volume, $localDirs, $filename );
    unless ( $volume ) {
        $localName = File::Spec->rel2abs( $localName, Cwd::getcwd() );
    }
    return $localName;
}

1;

__END__

#line 2060
FILE   5555a32a/Archive/Zip/Archive.pm  s#line 1 "/usr/share/perl5/Archive/Zip/Archive.pm"
package Archive::Zip::Archive;

# Represents a generic ZIP archive

use strict;
use File::Path;
use File::Find ();
use File::Spec ();
use File::Copy ();
use File::Basename;
use Cwd;

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

# Note that this returns undef on read errors, else new zip object.

sub new {
    my $class = shift;
    my $self  = bless(
        {
            'diskNumber'                            => 0,
            'diskNumberWithStartOfCentralDirectory' => 0,
            'numberOfCentralDirectoriesOnThisDisk'  => 0, # shld be # of members
            'numberOfCentralDirectories'            => 0, # shld be # of members
            'centralDirectorySize' => 0,    # must re-compute on write
            'centralDirectoryOffsetWRTStartingDiskNumber' =>
              0,                            # must re-compute
            'writeEOCDOffset'             => 0,
            'writeCentralDirectoryOffset' => 0,
            'zipfileComment'              => '',
            'eocdOffset'                  => 0,
            'fileName'                    => ''
        },
        $class
    );
    $self->{'members'} = [];
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{filename} : shift;
    if ($fileName) {
        my $status = $self->read($fileName);
        return $status == AZ_OK ? $self : undef;
    }
    return $self;
}

sub storeSymbolicLink {
    my $self = shift;
    $self->{'storeSymbolicLink'} = shift;
}

sub members {
    @{ shift->{'members'} };
}

sub numberOfMembers {
    scalar( shift->members() );
}

sub memberNames {
    my $self = shift;
    return map { $_->fileName() } $self->members();
}

# return ref to member with given name or undef
sub memberNamed {
    my $self     = shift;
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{zipName} : shift;
    foreach my $member ( $self->members() ) {
        return $member if $member->fileName() eq $fileName;
    }
    return undef;
}

sub membersMatching {
    my $self    = shift;
    my $pattern = ( ref( $_[0] ) eq 'HASH' ) ? shift->{regex} : shift;
    return grep { $_->fileName() =~ /$pattern/ } $self->members();
}

sub diskNumber {
    shift->{'diskNumber'};
}

sub diskNumberWithStartOfCentralDirectory {
    shift->{'diskNumberWithStartOfCentralDirectory'};
}

sub numberOfCentralDirectoriesOnThisDisk {
    shift->{'numberOfCentralDirectoriesOnThisDisk'};
}

sub numberOfCentralDirectories {
    shift->{'numberOfCentralDirectories'};
}

sub centralDirectorySize {
    shift->{'centralDirectorySize'};
}

sub centralDirectoryOffsetWRTStartingDiskNumber {
    shift->{'centralDirectoryOffsetWRTStartingDiskNumber'};
}

sub zipfileComment {
    my $self    = shift;
    my $comment = $self->{'zipfileComment'};
    if (@_) {
        my $new_comment = ( ref( $_[0] ) eq 'HASH' ) ? shift->{comment} : shift;
        $self->{'zipfileComment'} = pack( 'C0a*', $new_comment );    # avoid unicode
    }
    return $comment;
}

sub eocdOffset {
    shift->{'eocdOffset'};
}

# Return the name of the file last read.
sub fileName {
    shift->{'fileName'};
}

sub removeMember {
    my $self    = shift;
    my $member  = ( ref( $_[0] ) eq 'HASH' ) ? shift->{memberOrZipName} : shift;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    my @newMembers = grep { $_ != $member } $self->members();
    $self->{'members'} = \@newMembers;
    return $member;
}

sub replaceMember {
    my $self = shift;

    my ( $oldMember, $newMember );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $oldMember = $_[0]->{memberOrZipName};
        $newMember = $_[0]->{newMember};
    }
    else {
        ( $oldMember, $newMember ) = @_;
    }

    $oldMember = $self->memberNamed($oldMember) unless ref($oldMember);
    return undef unless $oldMember;
    return undef unless $newMember;
    my @newMembers =
      map { ( $_ == $oldMember ) ? $newMember : $_ } $self->members();
    $self->{'members'} = \@newMembers;
    return $oldMember;
}

sub extractMember {
    my $self = shift;

    my ( $member, $name );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $member = $_[0]->{memberOrZipName};
        $name   = $_[0]->{name};
    }
    else {
        ( $member, $name ) = @_;
    }

    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    my ( $volumeName, $dirName, $fileName );
    if ( defined($name) ) {
        ( $volumeName, $dirName, $fileName ) = File::Spec->splitpath($name);
        $dirName = File::Spec->catpath( $volumeName, $dirName, '' );
    }
    else {
        $name = $member->fileName();
        ( $dirName = $name ) =~ s{[^/]*$}{};
        $dirName = Archive::Zip::_asLocalName($dirName);
        $name    = Archive::Zip::_asLocalName($name);
    }
    if ( $dirName && !-d $dirName ) {
        mkpath($dirName);
        return _ioError("can't create dir $dirName") if ( !-d $dirName );
    }
    my $rc = $member->extractToFileNamed( $name, @_ );

    # TODO refactor this fix into extractToFileNamed()
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub extractMemberWithoutPaths {
    my $self = shift;

    my ( $member, $name );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $member = $_[0]->{memberOrZipName};
        $name   = $_[0]->{name};
    }
    else {
        ( $member, $name ) = @_;
    }

    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    return AZ_OK if $member->isDirectory();
    unless ($name) {
        $name = $member->fileName();
        $name =~ s{.*/}{};    # strip off directories, if any
        $name = Archive::Zip::_asLocalName($name);
    }
    my $rc = $member->extractToFileNamed( $name, @_ );
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub addMember {
    my $self       = shift;
    my $newMember  = ( ref( $_[0] ) eq 'HASH' ) ? shift->{member} : shift;
    push( @{ $self->{'members'} }, $newMember ) if $newMember;
    return $newMember;
}

sub addFile {
    my $self = shift;

    my ( $fileName, $newName, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fileName         = $_[0]->{filename};
        $newName          = $_[0]->{zipName};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $fileName, $newName, $compressionLevel ) = @_;
    }

    my $newMember = $self->ZIPMEMBERCLASS->newFromFile( $fileName, $newName );
    $newMember->desiredCompressionLevel($compressionLevel);
    if ( $self->{'storeSymbolicLink'} && -l $fileName ) {
        my $newMember = $self->ZIPMEMBERCLASS->newFromString(readlink $fileName, $newName);
        # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    return $newMember;
}

sub addString {
    my $self = shift;

    my ( $stringOrStringRef, $name, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $stringOrStringRef = $_[0]->{string};
        $name              = $_[0]->{zipName};
        $compressionLevel  = $_[0]->{compressionLevel};
    }
    else {
        ( $stringOrStringRef, $name, $compressionLevel ) = @_;;
    }

    my $newMember = $self->ZIPMEMBERCLASS->newFromString(
        $stringOrStringRef, $name
    );
    $newMember->desiredCompressionLevel($compressionLevel);
    return $self->addMember($newMember);
}

sub addDirectory {
    my $self = shift;

    my ( $name, $newName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $name    = $_[0]->{directoryName};
        $newName = $_[0]->{zipName};
    }
    else {
        ( $name, $newName ) = @_;
    }

    my $newMember = $self->ZIPMEMBERCLASS->newDirectoryNamed( $name, $newName );
    if ( $self->{'storeSymbolicLink'} && -l $name ) {
        my $link = readlink $name;
        ( $newName =~ s{/$}{} ) if $newName; # Strip trailing /
        my $newMember = $self->ZIPMEMBERCLASS->newFromString($link, $newName);
        # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    return $newMember;
}

# add either a file or a directory.

sub addFileOrDirectory {
    my $self = shift;

    my ( $name, $newName, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $name             = $_[0]->{name};
        $newName          = $_[0]->{zipName};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $name, $newName, $compressionLevel ) = @_;
    }

    $name =~ s{/$}{};
    if ( $newName ) {
        $newName =~ s{/$}{};
    } else {
        $newName = $name;
    }
    if ( -f $name ) {
        return $self->addFile( $name, $newName, $compressionLevel );
    }
    elsif ( -d $name ) {
        return $self->addDirectory( $name, $newName );
    }
    else {
        return _error("$name is neither a file nor a directory");
    }
}

sub contents {
    my $self = shift;

    my ( $member, $newContents );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $member      = $_[0]->{memberOrZipName};
        $newContents = $_[0]->{contents};
    }
    else {
        ( $member, $newContents ) = @_;
    }

    return _error('No member name given') unless $member;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    return $member->contents($newContents);
}

sub writeToFileNamed {
    my $self = shift;
    my $fileName =
      ( ref( $_[0] ) eq 'HASH' ) ? shift->{filename} : shift;  # local FS format
    foreach my $member ( $self->members() ) {
        if ( $member->_usesFileNamed($fileName) ) {
            return _error( "$fileName is needed by member "
                  . $member->fileName()
                  . "; consider using overwrite() or overwriteAs() instead." );
        }
    }
    my ( $status, $fh ) = _newFileHandle( $fileName, 'w' );
    return _ioError("Can't open $fileName for write") unless $status;
    my $retval = $self->writeToFileHandle( $fh, 1 );
    $fh->close();
    $fh = undef;

    return $retval;
}

# It is possible to write data to the FH before calling this,
# perhaps to make a self-extracting archive.
sub writeToFileHandle {
    my $self = shift;

    my ( $fh, $fhIsSeekable );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fh           = $_[0]->{fileHandle};
        $fhIsSeekable =
          exists( $_[0]->{seek} ) ? $_[0]->{seek} : _isSeekable($fh);
    }
    else {
        $fh           = shift;
        $fhIsSeekable = @_ ? shift : _isSeekable($fh);
    }

    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();
    _binmode($fh);

    # Find out where the current position is.
    my $offset = $fhIsSeekable ? $fh->tell() : 0;
    $offset    = 0 if $offset < 0;

    foreach my $member ( $self->members() ) {
        my $retval = $member->_writeToFileHandle( $fh, $fhIsSeekable, $offset );
        $member->endRead();
        return $retval if $retval != AZ_OK;
        $offset += $member->_localHeaderSize() + $member->_writeOffset();
        $offset +=
          $member->hasDataDescriptor()
          ? DATA_DESCRIPTOR_LENGTH + SIGNATURE_LENGTH
          : 0;

        # changed this so it reflects the last successful position
        $self->{'writeCentralDirectoryOffset'} = $offset;
    }
    return $self->writeCentralDirectory($fh);
}

# Write zip back to the original file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwrite {
    my $self = shift;
    return $self->overwriteAs( $self->{'fileName'} );
}

# Write zip to the specified file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwriteAs {
    my $self    = shift;
    my $zipName = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{filename} : shift;
    return _error("no filename in overwriteAs()") unless defined($zipName);

    my ( $fh, $tempName ) = Archive::Zip::tempFile();
    return _error( "Can't open temp file", $! ) unless $fh;

    ( my $backupName = $zipName ) =~ s{(\.[^.]*)?$}{.zbk};

    my $status = $self->writeToFileHandle($fh);
    $fh->close();
    $fh = undef;

    if ( $status != AZ_OK ) {
        unlink($tempName);
        _printError("Can't write to $tempName");
        return $status;
    }

    my $err;

    # rename the zip
    if ( -f $zipName && !rename( $zipName, $backupName ) ) {
        $err = $!;
        unlink($tempName);
        return _error( "Can't rename $zipName as $backupName", $err );
    }

    # move the temp to the original name (possibly copying)
    unless ( File::Copy::move( $tempName, $zipName ) ) {
        $err = $!;
        rename( $backupName, $zipName );
        unlink($tempName);
        return _error( "Can't move $tempName to $zipName", $err );
    }

    # unlink the backup
    if ( -f $backupName && !unlink($backupName) ) {
        $err = $!;
        return _error( "Can't unlink $backupName", $err );
    }

    return AZ_OK;
}

# Used only during writing
sub _writeCentralDirectoryOffset {
    shift->{'writeCentralDirectoryOffset'};
}

sub _writeEOCDOffset {
    shift->{'writeEOCDOffset'};
}

# Expects to have _writeEOCDOffset() set
sub _writeEndOfCentralDirectory {
    my ( $self, $fh ) = @_;

    $self->_print($fh, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING)
      or return _ioError('writing EOCD Signature');
    my $zipfileCommentLength = length( $self->zipfileComment() );

    my $header = pack(
        END_OF_CENTRAL_DIRECTORY_FORMAT,
        0,                          # {'diskNumber'},
        0,                          # {'diskNumberWithStartOfCentralDirectory'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectoriesOnThisDisk'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectories'},
        $self->_writeEOCDOffset() - $self->_writeCentralDirectoryOffset(),
        $self->_writeCentralDirectoryOffset(),
        $zipfileCommentLength
    );
    $self->_print($fh, $header)
      or return _ioError('writing EOCD header');
    if ($zipfileCommentLength) {
        $self->_print($fh,  $self->zipfileComment() )
          or return _ioError('writing zipfile comment');
    }
    return AZ_OK;
}

# $offset can be specified to truncate a zip file.
sub writeCentralDirectory {
    my $self = shift;

    my ( $fh, $offset );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fh     = $_[0]->{fileHandle};
        $offset = $_[0]->{offset};
    }
    else {
        ( $fh, $offset ) = @_;
    }

    if ( defined($offset) ) {
        $self->{'writeCentralDirectoryOffset'} = $offset;
        $fh->seek( $offset, IO::Seekable::SEEK_SET )
          or return _ioError('seeking to write central directory');
    }
    else {
        $offset = $self->_writeCentralDirectoryOffset();
    }

    foreach my $member ( $self->members() ) {
        my $status = $member->_writeCentralDirectoryFileHeader($fh);
        return $status if $status != AZ_OK;
        $offset += $member->_centralDirectoryHeaderSize();
        $self->{'writeEOCDOffset'} = $offset;
    }
    return $self->_writeEndOfCentralDirectory($fh);
}

sub read {
    my $self     = shift;
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{filename} : shift;
    return _error('No filename given') unless $fileName;
    my ( $status, $fh ) = _newFileHandle( $fileName, 'r' );
    return _ioError("opening $fileName for read") unless $status;

    $status = $self->readFromFileHandle( $fh, $fileName );
    return $status if $status != AZ_OK;

    $fh->close();
    $self->{'fileName'} = $fileName;
    return AZ_OK;
}

sub readFromFileHandle {
    my $self = shift;

    my ( $fh, $fileName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fh       = $_[0]->{fileHandle};
        $fileName = $_[0]->{filename};
    }
    else {
        ( $fh, $fileName ) = @_;
    }

    $fileName = $fh unless defined($fileName);
    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();

    _binmode($fh);
    $self->{'fileName'} = "$fh";

    # TODO: how to support non-seekable zips?
    return _error('file not seekable')
      unless _isSeekable($fh);

    $fh->seek( 0, 0 );    # rewind the file

    my $status = $self->_findEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    my $eocdPosition = $fh->tell();

    $status = $self->_readEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    $fh->seek( $eocdPosition - $self->centralDirectorySize(),
        IO::Seekable::SEEK_SET )
      or return _ioError("Can't seek $fileName");

    # Try to detect garbage at beginning of archives
    # This should be 0
    $self->{'eocdOffset'} = $eocdPosition - $self->centralDirectorySize() # here
      - $self->centralDirectoryOffsetWRTStartingDiskNumber();

    for ( ; ; ) {
        my $newMember =
          $self->ZIPMEMBERCLASS->_newFromZipFile( $fh, $fileName,
            $self->eocdOffset() );
        my $signature;
        ( $status, $signature ) = _readSignature( $fh, $fileName );
        return $status if $status != AZ_OK;
        last           if $signature == END_OF_CENTRAL_DIRECTORY_SIGNATURE;
        $status = $newMember->_readCentralDirectoryFileHeader();
        return $status if $status != AZ_OK;
        $status = $newMember->endRead();
        return $status if $status != AZ_OK;
        $newMember->_becomeDirectoryIfNecessary();
        push( @{ $self->{'members'} }, $newMember );
    }

    return AZ_OK;
}

# Read EOCD, starting from position before signature.
# Return AZ_OK on success.
sub _readEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;

    # Skip past signature
    $fh->seek( SIGNATURE_LENGTH, IO::Seekable::SEEK_CUR )
      or return _ioError("Can't seek past EOCD signature");

    my $header = '';
    my $bytesRead = $fh->read( $header, END_OF_CENTRAL_DIRECTORY_LENGTH );
    if ( $bytesRead != END_OF_CENTRAL_DIRECTORY_LENGTH ) {
        return _ioError("reading end of central directory");
    }

    my $zipfileCommentLength;
    (
        $self->{'diskNumber'},
        $self->{'diskNumberWithStartOfCentralDirectory'},
        $self->{'numberOfCentralDirectoriesOnThisDisk'},
        $self->{'numberOfCentralDirectories'},
        $self->{'centralDirectorySize'},
        $self->{'centralDirectoryOffsetWRTStartingDiskNumber'},
        $zipfileCommentLength
    ) = unpack( END_OF_CENTRAL_DIRECTORY_FORMAT, $header );

    if ($zipfileCommentLength) {
        my $zipfileComment = '';
        $bytesRead = $fh->read( $zipfileComment, $zipfileCommentLength );
        if ( $bytesRead != $zipfileCommentLength ) {
            return _ioError("reading zipfile comment");
        }
        $self->{'zipfileComment'} = $zipfileComment;
    }

    return AZ_OK;
}

# Seek in my file to the end, then read backwards until we find the
# signature of the central directory record. Leave the file positioned right
# before the signature. Returns AZ_OK if success.
sub _findEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;
    my $data = '';
    $fh->seek( 0, IO::Seekable::SEEK_END )
      or return _ioError("seeking to end");

    my $fileLength = $fh->tell();
    if ( $fileLength < END_OF_CENTRAL_DIRECTORY_LENGTH + 4 ) {
        return _formatError("file is too short");
    }

    my $seekOffset = 0;
    my $pos        = -1;
    for ( ; ; ) {
        $seekOffset += 512;
        $seekOffset = $fileLength if ( $seekOffset > $fileLength );
        $fh->seek( -$seekOffset, IO::Seekable::SEEK_END )
          or return _ioError("seek failed");
        my $bytesRead = $fh->read( $data, $seekOffset );
        if ( $bytesRead != $seekOffset ) {
            return _ioError("read failed");
        }
        $pos = rindex( $data, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING );
        last
          if ( $pos >= 0
            or $seekOffset == $fileLength
            or $seekOffset >= $Archive::Zip::ChunkSize );
    }

    if ( $pos >= 0 ) {
        $fh->seek( $pos - $seekOffset, IO::Seekable::SEEK_CUR )
          or return _ioError("seeking to EOCD");
        return AZ_OK;
    }
    else {
        return _formatError("can't find EOCD signature");
    }
}

# Used to avoid taint problems when chdir'ing.
# Not intended to increase security in any way; just intended to shut up the -T
# complaints.  If your Cwd module is giving you unreliable returns from cwd()
# you have bigger problems than this.
sub _untaintDir {
    my $dir = shift;
    $dir =~ m/\A(.+)\z/s;
    return $1;
}

sub addTree {
    my $self = shift;

    my ( $root, $dest, $pred, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pred             = $_[0]->{select};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $root, $dest, $pred, $compressionLevel ) = @_;
    }

    return _error("root arg missing in call to addTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r } unless defined($pred);

    my @files;
    my $startDir = _untaintDir( cwd() );

    return _error( 'undef returned by _untaintDir on cwd ', cwd() )
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        push( @files, $File::Find::name ) if (&$pred);
        chdir($dir);
    };

    File::Find::find( $wanted, $root );

    my $rootZipName = _asZipDirName( $root, 1 );    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    $dest = _asZipDirName( $dest, 1 );              # with trailing slash

    foreach my $fileName (@files) {
        my $isDir = -d $fileName;

        # normalize, remove leading ./
        my $archiveName = _asZipDirName( $fileName, $isDir );
        if ( $archiveName eq $rootZipName ) { $archiveName = $dest }
        else { $archiveName =~ s{$pattern}{$dest} }
        next if $archiveName =~ m{^\.?/?$};         # skip current dir
        my $member = $isDir
          ? $self->addDirectory( $fileName, $archiveName )
          : $self->addFile( $fileName, $archiveName );
        $member->desiredCompressionLevel($compressionLevel);

        return _error("add $fileName failed in addTree()") if !$member;
    }
    return AZ_OK;
}

sub addTreeMatching {
    my $self = shift;

    my ( $root, $dest, $pattern, $pred, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pattern          = $_[0]->{pattern};
        $pred             = $_[0]->{select};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $root, $dest, $pattern, $pred, $compressionLevel ) = @_;
    }

    return _error("root arg missing in call to addTreeMatching()")
      unless defined($root);
    $dest = '' unless defined($dest);
    return _error("pattern missing in call to addTreeMatching()")
      unless defined($pattern);
    my $matcher =
      $pred ? sub { m{$pattern} && &$pred } : sub { m{$pattern} && -r };
    return $self->addTree( $root, $dest, $matcher, $compressionLevel );
}

# $zip->extractTree( $root, $dest [, $volume] );
#
# $root and $dest are Unix-style.
# $volume is in local FS format.
#
sub extractTree {
    my $self = shift;

    my ( $root, $dest, $volume );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root   = $_[0]->{root};
        $dest   = $_[0]->{zipName};
        $volume = $_[0]->{volume};
    }
    else {
        ( $root, $dest, $volume ) = @_;
    }

    $root = '' unless defined($root);
    $dest = './' unless defined($dest);
    my $pattern = "^\Q$root";
    my @members = $self->membersMatching($pattern);

    foreach my $member (@members) {
        my $fileName = $member->fileName();           # in Unix format
        $fileName =~ s{$pattern}{$dest};    # in Unix format
                                            # convert to platform format:
        $fileName = Archive::Zip::_asLocalName( $fileName, $volume );
        my $status = $member->extractToFileNamed($fileName);
        return $status if $status != AZ_OK;
    }
    return AZ_OK;
}

# $zip->updateMember( $memberOrName, $fileName );
# Returns (possibly updated) member, if any; undef on errors.

sub updateMember {
    my $self = shift;

    my ( $oldMember, $fileName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $oldMember = $_[0]->{memberOrZipName};
        $fileName  = $_[0]->{name};
    }
    else {
        ( $oldMember, $fileName ) = @_;
    }

    if ( !defined($fileName) ) {
        _error("updateMember(): missing fileName argument");
        return undef;
    }

    my @newStat = stat($fileName);
    if ( !@newStat ) {
        _ioError("Can't stat $fileName");
        return undef;
    }

    my $isDir = -d _;

    my $memberName;

    if ( ref($oldMember) ) {
        $memberName = $oldMember->fileName();
    }
    else {
        $oldMember = $self->memberNamed( $memberName = $oldMember )
          || $self->memberNamed( $memberName =
              _asZipDirName( $oldMember, $isDir ) );
    }

    unless ( defined($oldMember)
        && $oldMember->lastModTime() == $newStat[9]
        && $oldMember->isDirectory() == $isDir
        && ( $isDir || ( $oldMember->uncompressedSize() == $newStat[7] ) ) )
    {

        # create the new member
        my $newMember = $isDir
          ? $self->ZIPMEMBERCLASS->newDirectoryNamed( $fileName, $memberName )
          : $self->ZIPMEMBERCLASS->newFromFile( $fileName, $memberName );

        unless ( defined($newMember) ) {
            _error("creation of member $fileName failed in updateMember()");
            return undef;
        }

        # replace old member or append new one
        if ( defined($oldMember) ) {
            $self->replaceMember( $oldMember, $newMember );
        }
        else { $self->addMember($newMember); }

        return $newMember;
    }

    return $oldMember;
}

# $zip->updateTree( $root, [ $dest, [ $pred [, $mirror]]] );
#
# This takes the same arguments as addTree, but first checks to see
# whether the file or directory already exists in the zip file.
#
# If the fourth argument $mirror is true, then delete all my members
# if corresponding files weren't found.

sub updateTree {
    my $self = shift;

    my ( $root, $dest, $pred, $mirror, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pred             = $_[0]->{select};
        $mirror           = $_[0]->{mirror};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $root, $dest, $pred, $mirror, $compressionLevel ) = @_;
    }

    return _error("root arg missing in call to updateTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r } unless defined($pred);

    $dest = _asZipDirName( $dest, 1 );
    my $rootZipName = _asZipDirName( $root, 1 );    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    my @files;
    my $startDir = _untaintDir( cwd() );

    return _error( 'undef returned by _untaintDir on cwd ', cwd() )
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        push( @files, $File::Find::name ) if (&$pred);
        chdir($dir);
    };

    File::Find::find( $wanted, $root );

    # Now @files has all the files that I could potentially be adding to
    # the zip. Only add the ones that are necessary.
    # For each file (updated or not), add its member name to @done.
    my %done;
    foreach my $fileName (@files) {
        my @newStat = stat($fileName);
        my $isDir   = -d _;

        # normalize, remove leading ./
        my $memberName = _asZipDirName( $fileName, $isDir );
        if ( $memberName eq $rootZipName ) { $memberName = $dest }
        else { $memberName =~ s{$pattern}{$dest} }
        next if $memberName =~ m{^\.?/?$};    # skip current dir

        $done{$memberName} = 1;
        my $changedMember = $self->updateMember( $memberName, $fileName );
        $changedMember->desiredCompressionLevel($compressionLevel);
        return _error("updateTree failed to update $fileName")
          unless ref($changedMember);
    }

    # @done now has the archive names corresponding to all the found files.
    # If we're mirroring, delete all those members that aren't in @done.
    if ($mirror) {
        foreach my $member ( $self->members() ) {
            $self->removeMember($member)
              unless $done{ $member->fileName() };
        }
    }

    return AZ_OK;
}

1;
FILE   '078c7557/Archive/Zip/DirectoryMember.pm  	#line 1 "/usr/share/perl5/Archive/Zip/DirectoryMember.pm"
package Archive::Zip::DirectoryMember;

use strict;
use File::Path;

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip::Member );
}

use Archive::Zip qw(
  :ERROR_CODES
  :UTILITY_METHODS
);

sub _newNamed {
    my $class    = shift;
    my $fileName = shift;    # FS name
    my $newName  = shift;    # Zip name
    $newName = _asZipDirName($fileName) unless $newName;
    my $self = $class->new(@_);
    $self->{'externalFileName'} = $fileName;
    $self->fileName($newName);

    if ( -e $fileName ) {

        # -e does NOT do a full stat, so we need to do one now
        if ( -d _ ) {
            my @stat = stat(_);
            $self->unixFileAttributes( $stat[2] );
            my $mod_t = $stat[9];
            if ( $^O eq 'MSWin32' and !$mod_t ) {
                $mod_t = time();
            }
            $self->setLastModFileDateTimeFromUnix($mod_t);

        } else {    # hmm.. trying to add a non-directory?
            _error( $fileName, ' exists but is not a directory' );
            return undef;
        }
    } else {
        $self->unixFileAttributes( $self->DEFAULT_DIRECTORY_PERMISSIONS );
        $self->setLastModFileDateTimeFromUnix( time() );
    }
    return $self;
}

sub externalFileName {
    shift->{'externalFileName'};
}

sub isDirectory {
    return 1;
}

sub extractToFileNamed {
    my $self    = shift;
    my $name    = shift;                                 # local FS name
    my $attribs = $self->unixFileAttributes() & 07777;
    mkpath( $name, 0, $attribs );                        # croaks on error
    utime( $self->lastModTime(), $self->lastModTime(), $name );
    return AZ_OK;
}

sub fileName {
    my $self    = shift;
    my $newName = shift;
    $newName =~ s{/?$}{/} if defined($newName);
    return $self->SUPER::fileName($newName);
}

# So people don't get too confused. This way it looks like the problem
# is in their code...
sub contents {
    return wantarray ? ( undef, AZ_OK ) : undef;
}

1;
FILE   "4f1c027b/Archive/Zip/FileMember.pm  }#line 1 "/usr/share/perl5/Archive/Zip/FileMember.pm"
package Archive::Zip::FileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw ( Archive::Zip::Member );
}

use Archive::Zip qw(
  :UTILITY_METHODS
);

sub externalFileName {
    shift->{'externalFileName'};
}

# Return true if I depend on the named file
sub _usesFileNamed {
    my $self     = shift;
    my $fileName = shift;
    my $xfn      = $self->externalFileName();
    return undef if ref($xfn);
    return $xfn eq $fileName;
}

sub fh {
    my $self = shift;
    $self->_openFile()
      if !defined( $self->{'fh'} ) || !$self->{'fh'}->opened();
    return $self->{'fh'};
}

# opens my file handle from my file name
sub _openFile {
    my $self = shift;
    my ( $status, $fh ) = _newFileHandle( $self->externalFileName(), 'r' );
    if ( !$status ) {
        _ioError( "Can't open", $self->externalFileName() );
        return undef;
    }
    $self->{'fh'} = $fh;
    _binmode($fh);
    return $fh;
}

# Make sure I close my file handle
sub endRead {
    my $self = shift;
    undef $self->{'fh'};    # _closeFile();
    return $self->SUPER::endRead(@_);
}

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;
    delete( $self->{'externalFileName'} );
    delete( $self->{'fh'} );
    return $self->SUPER::_become($newClass);
}

1;
FILE   7519660c/Archive/Zip/Member.pm  `#line 1 "/usr/share/perl5/Archive/Zip/Member.pm"
package Archive::Zip::Member;

# A generic membet of an archive

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip );
}

use Archive::Zip qw(
  :CONSTANTS
  :MISC_CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

use Time::Local ();
use Compress::Raw::Zlib qw( Z_OK Z_STREAM_END MAX_WBITS );
use File::Path;
use File::Basename;

use constant ZIPFILEMEMBERCLASS   => 'Archive::Zip::ZipFileMember';
use constant NEWFILEMEMBERCLASS   => 'Archive::Zip::NewFileMember';
use constant STRINGMEMBERCLASS    => 'Archive::Zip::StringMember';
use constant DIRECTORYMEMBERCLASS => 'Archive::Zip::DirectoryMember';

# Unix perms for default creation of files/dirs.
use constant DEFAULT_DIRECTORY_PERMISSIONS => 040755;
use constant DEFAULT_FILE_PERMISSIONS      => 0100666;
use constant DIRECTORY_ATTRIB              => 040000;
use constant FILE_ATTRIB                   => 0100000;

# Returns self if successful, else undef
# Assumes that fh is positioned at beginning of central directory file header.
# Leaves fh positioned immediately after file header or EOCD signature.
sub _newFromZipFile {
    my $class = shift;
    my $self  = $class->ZIPFILEMEMBERCLASS->_newFromZipFile(@_);
    return $self;
}

sub newFromString {
    my $class = shift;

    my ( $stringOrStringRef, $fileName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $stringOrStringRef = $_[0]->{string};
        $fileName          = $_[0]->{zipName};
    }
    else {
        ( $stringOrStringRef, $fileName ) = @_;
    }

    my $self  = $class->STRINGMEMBERCLASS->_newFromString( $stringOrStringRef,
        $fileName );
    return $self;
}

sub newFromFile {
    my $class = shift;

    my ( $fileName, $zipName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fileName = $_[0]->{fileName};
        $zipName  = $_[0]->{zipName};
    }
    else {
        ( $fileName, $zipName ) = @_;
    }

    my $self = $class->NEWFILEMEMBERCLASS->_newFromFileNamed( $fileName,
      $zipName );
    return $self;
}

sub newDirectoryNamed {
    my $class = shift;

    my ( $directoryName, $newName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $directoryName = $_[0]->{directoryName};
        $newName       = $_[0]->{zipName};
    }
    else {
        ( $directoryName, $newName ) = @_;
    }

    my $self  = $class->DIRECTORYMEMBERCLASS->_newNamed( $directoryName,
        $newName );
    return $self;
}

sub new {
    my $class = shift;
    my $self  = {
        'lastModFileDateTime'      => 0,
        'fileAttributeFormat'      => FA_UNIX,
        'versionMadeBy'            => 20,
        'versionNeededToExtract'   => 20,
        'bitFlag'                  => 0,
        'compressionMethod'        => COMPRESSION_STORED,
        'desiredCompressionMethod' => COMPRESSION_STORED,
        'desiredCompressionLevel'  => COMPRESSION_LEVEL_NONE,
        'internalFileAttributes'   => 0,
        'externalFileAttributes'   => 0,                        # set later
        'fileName'                 => '',
        'cdExtraField'             => '',
        'localExtraField'          => '',
        'fileComment'              => '',
        'crc32'                    => 0,
        'compressedSize'           => 0,
        'uncompressedSize'         => 0,
        'isSymbolicLink'           => 0,
        @_
    };
    bless( $self, $class );
    $self->unixFileAttributes( $self->DEFAULT_FILE_PERMISSIONS );
    return $self;
}

sub _becomeDirectoryIfNecessary {
    my $self = shift;
    $self->_become(DIRECTORYMEMBERCLASS)
      if $self->isDirectory();
    return $self;
}

# Morph into given class (do whatever cleanup I need to do)
sub _become {
    return bless( $_[0], $_[1] );
}

sub versionMadeBy {
    shift->{'versionMadeBy'};
}

sub fileAttributeFormat {
    my $self = shift;

    if (@_) {
        $self->{fileAttributeFormat} = ( ref( $_[0] ) eq 'HASH' )
        ? $_[0]->{format} : $_[0];
    }
    else {
        return $self->{fileAttributeFormat};
    }
}

sub versionNeededToExtract {
    shift->{'versionNeededToExtract'};
}

sub bitFlag {
    my $self = shift;

    # Set General Purpose Bit Flags according to the desiredCompressionLevel setting
    if ( $self->desiredCompressionLevel == 1 || $self->desiredCompressionLevel == 2 ) {
        $self->{'bitFlag'} = DEFLATING_COMPRESSION_FAST;
    } elsif ( $self->desiredCompressionLevel == 3 || $self->desiredCompressionLevel == 4
          || $self->desiredCompressionLevel == 5 || $self->desiredCompressionLevel == 6
          || $self->desiredCompressionLevel == 7 ) {
        $self->{'bitFlag'} = DEFLATING_COMPRESSION_NORMAL;
    } elsif ( $self->desiredCompressionLevel == 8 || $self->desiredCompressionLevel == 9 ) {
        $self->{'bitFlag'} = DEFLATING_COMPRESSION_MAXIMUM;
    }
    $self->{'bitFlag'};
}

sub compressionMethod {
    shift->{'compressionMethod'};
}

sub desiredCompressionMethod {
    my $self = shift;
    my $newDesiredCompressionMethod =
      ( ref( $_[0] ) eq 'HASH' ) ? shift->{compressionMethod} : shift;
    my $oldDesiredCompressionMethod = $self->{'desiredCompressionMethod'};
    if ( defined($newDesiredCompressionMethod) ) {
        $self->{'desiredCompressionMethod'} = $newDesiredCompressionMethod;
        if ( $newDesiredCompressionMethod == COMPRESSION_STORED ) {
            $self->{'desiredCompressionLevel'} = 0;
            $self->{'bitFlag'} &= ~GPBF_HAS_DATA_DESCRIPTOR_MASK;

        } elsif ( $oldDesiredCompressionMethod == COMPRESSION_STORED ) {
            $self->{'desiredCompressionLevel'} = COMPRESSION_LEVEL_DEFAULT;
        }
    }
    return $oldDesiredCompressionMethod;
}

sub desiredCompressionLevel {
    my $self = shift;
    my $newDesiredCompressionLevel =
      ( ref( $_[0] ) eq 'HASH' ) ? shift->{compressionLevel} : shift;
    my $oldDesiredCompressionLevel = $self->{'desiredCompressionLevel'};
    if ( defined($newDesiredCompressionLevel) ) {
        $self->{'desiredCompressionLevel'}  = $newDesiredCompressionLevel;
        $self->{'desiredCompressionMethod'} = (
            $newDesiredCompressionLevel
            ? COMPRESSION_DEFLATED
            : COMPRESSION_STORED
        );
    }
    return $oldDesiredCompressionLevel;
}

sub fileName {
    my $self    = shift;
    my $newName = shift;
    if ($newName) {
        $newName =~ s{[\\/]+}{/}g;    # deal with dos/windoze problems
        $self->{'fileName'} = $newName;
    }
    return $self->{'fileName'};
}

sub lastModFileDateTime {
    my $modTime = shift->{'lastModFileDateTime'};
    $modTime =~ m/^(\d+)$/;           # untaint
    return $1;
}

sub lastModTime {
    my $self = shift;
    return _dosToUnixTime( $self->lastModFileDateTime() );
}

sub setLastModFileDateTimeFromUnix {
    my $self   = shift;
    my $time_t = shift;
    $self->{'lastModFileDateTime'} = _unixToDosTime($time_t);
}

sub internalFileAttributes {
    shift->{'internalFileAttributes'};
}

sub externalFileAttributes {
    shift->{'externalFileAttributes'};
}

# Convert UNIX permissions into proper value for zip file
# Usable as a function or a method
sub _mapPermissionsFromUnix {
    my $self    = shift;
    my $mode    = shift;
    my $attribs = $mode << 16;

    # Microsoft Windows Explorer needs this bit set for directories
    if ( $mode & DIRECTORY_ATTRIB ) {
        $attribs |= 16;
    }

    return $attribs;

    # TODO: map more MS-DOS perms
}

# Convert ZIP permissions into Unix ones
#
# This was taken from Info-ZIP group's portable UnZip
# zipfile-extraction program, version 5.50.
# http://www.info-zip.org/pub/infozip/
#
# See the mapattr() function in unix/unix.c
# See the attribute format constants in unzpriv.h
#
# XXX Note that there's one situation that isn't implemented
# yet that depends on the "extra field."
sub _mapPermissionsToUnix {
    my $self = shift;

    my $format  = $self->{'fileAttributeFormat'};
    my $attribs = $self->{'externalFileAttributes'};

    my $mode = 0;

    if ( $format == FA_AMIGA ) {
        $attribs = $attribs >> 17 & 7;                         # Amiga RWE bits
        $mode    = $attribs << 6 | $attribs << 3 | $attribs;
        return $mode;
    }

    if ( $format == FA_THEOS ) {
        $attribs &= 0xF1FFFFFF;
        if ( ( $attribs & 0xF0000000 ) != 0x40000000 ) {
            $attribs &= 0x01FFFFFF;    # not a dir, mask all ftype bits
        }
        else {
            $attribs &= 0x41FFFFFF;    # leave directory bit as set
        }
    }

    if (   $format == FA_UNIX
        || $format == FA_VAX_VMS
        || $format == FA_ACORN
        || $format == FA_ATARI_ST
        || $format == FA_BEOS
        || $format == FA_QDOS
        || $format == FA_TANDEM )
    {
        $mode = $attribs >> 16;
        return $mode if $mode != 0 or not $self->localExtraField;

        # warn("local extra field is: ", $self->localExtraField, "\n");

        # XXX This condition is not implemented
        # I'm just including the comments from the info-zip section for now.

        # Some (non-Info-ZIP) implementations of Zip for Unix and
        # VMS (and probably others ??) leave 0 in the upper 16-bit
        # part of the external_file_attributes field. Instead, they
        # store file permission attributes in some extra field.
        # As a work-around, we search for the presence of one of
        # these extra fields and fall back to the MSDOS compatible
        # part of external_file_attributes if one of the known
        # e.f. types has been detected.
        # Later, we might implement extraction of the permission
        # bits from the VMS extra field. But for now, the work-around
        # should be sufficient to provide "readable" extracted files.
        # (For ASI Unix e.f., an experimental remap from the e.f.
        # mode value IS already provided!)
    }

    # PKWARE's PKZip for Unix marks entries as FA_MSDOS, but stores the
    # Unix attributes in the upper 16 bits of the external attributes
    # field, just like Info-ZIP's Zip for Unix.  We try to use that
    # value, after a check for consistency with the MSDOS attribute
    # bits (see below).
    if ( $format == FA_MSDOS ) {
        $mode = $attribs >> 16;
    }

    # FA_MSDOS, FA_OS2_HPFS, FA_WINDOWS_NTFS, FA_MACINTOSH, FA_TOPS20
    $attribs = !( $attribs & 1 ) << 1 | ( $attribs & 0x10 ) >> 4;

    # keep previous $mode setting when its "owner"
    # part appears to be consistent with DOS attribute flags!
    return $mode if ( $mode & 0700 ) == ( 0400 | $attribs << 6 );
    $mode = 0444 | $attribs << 6 | $attribs << 3 | $attribs;
    return $mode;
}

sub unixFileAttributes {
    my $self     = shift;
    my $oldPerms = $self->_mapPermissionsToUnix;

    my $perms;
    if ( @_ ) {
        $perms = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{attributes} : $_[0];

        if ( $self->isDirectory ) {
            $perms &= ~FILE_ATTRIB;
            $perms |= DIRECTORY_ATTRIB;
        } else {
            $perms &= ~DIRECTORY_ATTRIB;
            $perms |= FILE_ATTRIB;
        }
        $self->{externalFileAttributes} = $self->_mapPermissionsFromUnix($perms);
    }

    return $oldPerms;
}

sub localExtraField {
    my $self = shift;

    if (@_) {
        $self->{localExtraField} = ( ref( $_[0] ) eq 'HASH' )
          ? $_[0]->{field} : $_[0];
    }
    else {
        return $self->{localExtraField};
    }
}

sub cdExtraField {
    my $self = shift;

    if (@_) {
        $self->{cdExtraField} = ( ref( $_[0] ) eq 'HASH' )
          ? $_[0]->{field} : $_[0];
    }
    else {
        return $self->{cdExtraField};
    }
}

sub extraFields {
    my $self = shift;
    return $self->localExtraField() . $self->cdExtraField();
}

sub fileComment {
    my $self = shift;

    if (@_) {
        $self->{fileComment} = ( ref( $_[0] ) eq 'HASH' )
          ? pack( 'C0a*', $_[0]->{comment} ) : pack( 'C0a*', $_[0] );
    }
    else {
        return $self->{fileComment};
    }
}

sub hasDataDescriptor {
    my $self = shift;
    if (@_) {
        my $shouldHave = shift;
        if ($shouldHave) {
            $self->{'bitFlag'} |= GPBF_HAS_DATA_DESCRIPTOR_MASK;
        }
        else {
            $self->{'bitFlag'} &= ~GPBF_HAS_DATA_DESCRIPTOR_MASK;
        }
    }
    return $self->{'bitFlag'} & GPBF_HAS_DATA_DESCRIPTOR_MASK;
}

sub crc32 {
    shift->{'crc32'};
}

sub crc32String {
    sprintf( "%08x", shift->{'crc32'} );
}

sub compressedSize {
    shift->{'compressedSize'};
}

sub uncompressedSize {
    shift->{'uncompressedSize'};
}

sub isEncrypted {
    shift->bitFlag() & GPBF_ENCRYPTED_MASK;
}

sub isTextFile {
    my $self = shift;
    my $bit  = $self->internalFileAttributes() & IFA_TEXT_FILE_MASK;
    if (@_) {
        my $flag = ( ref( $_[0] ) eq 'HASH' ) ? shift->{flag} : shift;
        $self->{'internalFileAttributes'} &= ~IFA_TEXT_FILE_MASK;
        $self->{'internalFileAttributes'} |=
          ( $flag ? IFA_TEXT_FILE: IFA_BINARY_FILE );
    }
    return $bit == IFA_TEXT_FILE;
}

sub isBinaryFile {
    my $self = shift;
    my $bit  = $self->internalFileAttributes() & IFA_TEXT_FILE_MASK;
    if (@_) {
        my $flag = shift;
        $self->{'internalFileAttributes'} &= ~IFA_TEXT_FILE_MASK;
        $self->{'internalFileAttributes'} |=
          ( $flag ? IFA_BINARY_FILE: IFA_TEXT_FILE );
    }
    return $bit == IFA_BINARY_FILE;
}

sub extractToFileNamed {
    my $self = shift;

    # local FS name
    my $name = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{name} : $_[0];
    $self->{'isSymbolicLink'} = 0;

    # Check if the file / directory is a symbolic link or not
    if ( $self->{'externalFileAttributes'} == 0xA1FF0000 ) {
        $self->{'isSymbolicLink'} = 1;
        $self->{'newName'} = $name;
        my ( $status, $fh ) = _newFileHandle( $name, 'r' );
        my $retval = $self->extractToFileHandle($fh);
        $fh->close();
    } else {
        #return _writeSymbolicLink($self, $name) if $self->isSymbolicLink();
        return _error("encryption unsupported") if $self->isEncrypted();
        mkpath( dirname($name) );    # croaks on error
        my ( $status, $fh ) = _newFileHandle( $name, 'w' );
        return _ioError("Can't open file $name for write") unless $status;
        my $retval = $self->extractToFileHandle($fh);
        $fh->close();
        chmod ($self->unixFileAttributes(), $name)
            or return _error("Can't chmod() ${name}: $!");
        utime( $self->lastModTime(), $self->lastModTime(), $name );
        return $retval;
    }
}

sub _writeSymbolicLink {
    my $self = shift;
    my $name = shift;
    my $chunkSize = $Archive::Zip::ChunkSize;
    #my ( $outRef, undef ) = $self->readChunk($chunkSize);
    my $fh;
    my $retval = $self->extractToFileHandle($fh);
    my ( $outRef, undef ) = $self->readChunk(100);
}

sub isSymbolicLink {
    my $self = shift;
    if ( $self->{'externalFileAttributes'} == 0xA1FF0000 ) {
        $self->{'isSymbolicLink'} = 1;
    } else {
        return 0;
    }
    1;
}

sub isDirectory {
    return 0;
}

sub externalFileName {
    return undef;
}

# The following are used when copying data
sub _writeOffset {
    shift->{'writeOffset'};
}

sub _readOffset {
    shift->{'readOffset'};
}

sub writeLocalHeaderRelativeOffset {
    shift->{'writeLocalHeaderRelativeOffset'};
}

sub wasWritten { shift->{'wasWritten'} }

sub _dataEnded {
    shift->{'dataEnded'};
}

sub _readDataRemaining {
    shift->{'readDataRemaining'};
}

sub _inflater {
    shift->{'inflater'};
}

sub _deflater {
    shift->{'deflater'};
}

# Return the total size of my local header
sub _localHeaderSize {
    my $self = shift;
    return SIGNATURE_LENGTH + LOCAL_FILE_HEADER_LENGTH +
      length( $self->fileName() ) + length( $self->localExtraField() );
}

# Return the total size of my CD header
sub _centralDirectoryHeaderSize {
    my $self = shift;
    return SIGNATURE_LENGTH + CENTRAL_DIRECTORY_FILE_HEADER_LENGTH +
      length( $self->fileName() ) + length( $self->cdExtraField() ) +
      length( $self->fileComment() );
}

# DOS date/time format
# 0-4 (5) Second divided by 2
# 5-10 (6) Minute (0-59)
# 11-15 (5) Hour (0-23 on a 24-hour clock)
# 16-20 (5) Day of the month (1-31)
# 21-24 (4) Month (1 = January, 2 = February, etc.)
# 25-31 (7) Year offset from 1980 (add 1980 to get actual year)

# Convert DOS date/time format to unix time_t format
# NOT AN OBJECT METHOD!
sub _dosToUnixTime {
    my $dt = shift;
    return time() unless defined($dt);

    my $year = ( ( $dt >> 25 ) & 0x7f ) + 80;
    my $mon  = ( ( $dt >> 21 ) & 0x0f ) - 1;
    my $mday = ( ( $dt >> 16 ) & 0x1f );

    my $hour = ( ( $dt >> 11 ) & 0x1f );
    my $min  = ( ( $dt >> 5 ) & 0x3f );
    my $sec  = ( ( $dt << 1 ) & 0x3e );

    # catch errors
    my $time_t =
      eval { Time::Local::timelocal( $sec, $min, $hour, $mday, $mon, $year ); };
    return time() if ($@);
    return $time_t;
}

# Note, this isn't exactly UTC 1980, it's 1980 + 12 hours and 1
# minute so that nothing timezoney can muck us up.
my $safe_epoch = 315576060;

# convert a unix time to DOS date/time
# NOT AN OBJECT METHOD!
sub _unixToDosTime {
    my $time_t = shift;
    unless ($time_t) {
        _error("Tried to add member with zero or undef value for time");
        $time_t = $safe_epoch;
    }
    if ( $time_t < $safe_epoch ) {
        _ioError("Unsupported date before 1980 encountered, moving to 1980");
        $time_t = $safe_epoch;
    }
    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime($time_t);
    my $dt = 0;
    $dt += ( $sec >> 1 );
    $dt += ( $min << 5 );
    $dt += ( $hour << 11 );
    $dt += ( $mday << 16 );
    $dt += ( ( $mon + 1 ) << 21 );
    $dt += ( ( $year - 80 ) << 25 );
    return $dt;
}

# Write my local header to a file handle.
# Stores the offset to the start of the header in my
# writeLocalHeaderRelativeOffset member.
# Returns AZ_OK on success.
sub _writeLocalFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $signatureData = pack( SIGNATURE_FORMAT, LOCAL_FILE_HEADER_SIGNATURE );
    $self->_print($fh, $signatureData)
      or return _ioError("writing local header signature");

    my $header = pack(
        LOCAL_FILE_HEADER_FORMAT,
        $self->versionNeededToExtract(),
        $self->bitFlag(),
        $self->desiredCompressionMethod(),
        $self->lastModFileDateTime(),
        $self->crc32(),
        $self->compressedSize(),    # may need to be re-written later
        $self->uncompressedSize(),
        length( $self->fileName() ),
        length( $self->localExtraField() )
    );

    $self->_print($fh, $header) or return _ioError("writing local header");

    # Check for a valid filename or a filename equal to a literal `0'
    if ( $self->fileName() || $self->fileName eq '0' ) {
        $self->_print($fh, $self->fileName() )
          or return _ioError("writing local header filename");
    }
    if ( $self->localExtraField() ) {
        $self->_print($fh, $self->localExtraField() )
          or return _ioError("writing local extra field");
    }

    return AZ_OK;
}

sub _writeCentralDirectoryFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $sigData =
      pack( SIGNATURE_FORMAT, CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE );
    $self->_print($fh, $sigData)
      or return _ioError("writing central directory header signature");

    my $fileNameLength    = length( $self->fileName() );
    my $extraFieldLength  = length( $self->cdExtraField() );
    my $fileCommentLength = length( $self->fileComment() );

    my $header = pack(
        CENTRAL_DIRECTORY_FILE_HEADER_FORMAT,
        $self->versionMadeBy(),
        $self->fileAttributeFormat(),
        $self->versionNeededToExtract(),
        $self->bitFlag(),
        $self->desiredCompressionMethod(),
        $self->lastModFileDateTime(),
        $self->crc32(),            # these three fields should have been updated
        $self->_writeOffset(),     # by writing the data stream out
        $self->uncompressedSize(), #
        $fileNameLength,
        $extraFieldLength,
        $fileCommentLength,
        0,                         # {'diskNumberStart'},
        $self->internalFileAttributes(),
        $self->externalFileAttributes(),
        $self->writeLocalHeaderRelativeOffset()
    );

    $self->_print($fh, $header)
      or return _ioError("writing central directory header");
    if ($fileNameLength) {
        $self->_print($fh,  $self->fileName() )
          or return _ioError("writing central directory header signature");
    }
    if ($extraFieldLength) {
        $self->_print($fh,  $self->cdExtraField() )
          or return _ioError("writing central directory extra field");
    }
    if ($fileCommentLength) {
        $self->_print($fh,  $self->fileComment() )
          or return _ioError("writing central directory file comment");
    }

    return AZ_OK;
}

# This writes a data descriptor to the given file handle.
# Assumes that crc32, writeOffset, and uncompressedSize are
# set correctly (they should be after a write).
# Further, the local file header should have the
# GPBF_HAS_DATA_DESCRIPTOR_MASK bit set.
sub _writeDataDescriptor {
    my $self   = shift;
    my $fh     = shift;
    my $header = pack(
        SIGNATURE_FORMAT . DATA_DESCRIPTOR_FORMAT,
        DATA_DESCRIPTOR_SIGNATURE,
        $self->crc32(),
        $self->_writeOffset(),    # compressed size
        $self->uncompressedSize()
    );

    $self->_print($fh, $header)
      or return _ioError("writing data descriptor");
    return AZ_OK;
}

# Re-writes the local file header with new crc32 and compressedSize fields.
# To be called after writing the data stream.
# Assumes that filename and extraField sizes didn't change since last written.
sub _refreshLocalFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $here = $fh->tell();
    $fh->seek( $self->writeLocalHeaderRelativeOffset() + SIGNATURE_LENGTH,
        IO::Seekable::SEEK_SET )
      or return _ioError("seeking to rewrite local header");

    my $header = pack(
        LOCAL_FILE_HEADER_FORMAT,
        $self->versionNeededToExtract(),
        $self->bitFlag(),
        $self->desiredCompressionMethod(),
        $self->lastModFileDateTime(),
        $self->crc32(),
        $self->_writeOffset(),    # compressed size
        $self->uncompressedSize(),
        length( $self->fileName() ),
        length( $self->localExtraField() )
    );

    $self->_print($fh, $header)
      or return _ioError("re-writing local header");
    $fh->seek( $here, IO::Seekable::SEEK_SET )
      or return _ioError("seeking after rewrite of local header");

    return AZ_OK;
}

sub readChunk {
    my $self = shift;
    my $chunkSize = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{chunkSize} : $_[0];

    if ( $self->readIsDone() ) {
        $self->endRead();
        my $dummy = '';
        return ( \$dummy, AZ_STREAM_END );
    }

    $chunkSize = $Archive::Zip::ChunkSize if not defined($chunkSize);
    $chunkSize = $self->_readDataRemaining()
      if $chunkSize > $self->_readDataRemaining();

    my $buffer = '';
    my $outputRef;
    my ( $bytesRead, $status ) = $self->_readRawChunk( \$buffer, $chunkSize );
    return ( \$buffer, $status ) unless $status == AZ_OK;

    $self->{'readDataRemaining'} -= $bytesRead;
    $self->{'readOffset'} += $bytesRead;

    if ( $self->compressionMethod() == COMPRESSION_STORED ) {
        $self->{'crc32'} = $self->computeCRC32( $buffer, $self->{'crc32'} );
    }

    ( $outputRef, $status ) = &{ $self->{'chunkHandler'} }( $self, \$buffer );
    $self->{'writeOffset'} += length($$outputRef);

    $self->endRead()
      if $self->readIsDone();

    return ( $outputRef, $status );
}

# Read the next raw chunk of my data. Subclasses MUST implement.
#	my ( $bytesRead, $status) = $self->_readRawChunk( \$buffer, $chunkSize );
sub _readRawChunk {
    my $self = shift;
    return $self->_subclassResponsibility();
}

# A place holder to catch rewindData errors if someone ignores
# the error code.
sub _noChunk {
    my $self = shift;
    return ( \undef, _error("trying to copy chunk when init failed") );
}

# Basically a no-op so that I can have a consistent interface.
# ( $outputRef, $status) = $self->_copyChunk( \$buffer );
sub _copyChunk {
    my ( $self, $dataRef ) = @_;
    return ( $dataRef, AZ_OK );
}

# ( $outputRef, $status) = $self->_deflateChunk( \$buffer );
sub _deflateChunk {
    my ( $self, $buffer ) = @_;
    my ( $status ) = $self->_deflater()->deflate( $buffer, my $out );

    if ( $self->_readDataRemaining() == 0 ) {
        my $extraOutput;
        ( $status ) = $self->_deflater()->flush($extraOutput);
        $out .= $extraOutput;
        $self->endRead();
        return ( \$out, AZ_STREAM_END );
    }
    elsif ( $status == Z_OK ) {
        return ( \$out, AZ_OK );
    }
    else {
        $self->endRead();
        my $retval = _error( 'deflate error', $status );
        my $dummy = '';
        return ( \$dummy, $retval );
    }
}

# ( $outputRef, $status) = $self->_inflateChunk( \$buffer );
sub _inflateChunk {
    my ( $self, $buffer ) = @_;
    my ( $status ) = $self->_inflater()->inflate( $buffer, my $out );
    my $retval;
    $self->endRead() unless $status == Z_OK;
    if ( $status == Z_OK || $status == Z_STREAM_END ) {
        $retval = ( $status == Z_STREAM_END ) ? AZ_STREAM_END: AZ_OK;
        return ( \$out, $retval );
    }
    else {
        $retval = _error( 'inflate error', $status );
        my $dummy = '';
        return ( \$dummy, $retval );
    }
}

sub rewindData {
    my $self = shift;
    my $status;

    # set to trap init errors
    $self->{'chunkHandler'} = $self->can('_noChunk');

    # Work around WinZip bug with 0-length DEFLATED files
    $self->desiredCompressionMethod(COMPRESSION_STORED)
      if $self->uncompressedSize() == 0;

    # assume that we're going to read the whole file, and compute the CRC anew.
    $self->{'crc32'} = 0
      if ( $self->compressionMethod() == COMPRESSION_STORED );

    # These are the only combinations of methods we deal with right now.
    if (    $self->compressionMethod() == COMPRESSION_STORED
        and $self->desiredCompressionMethod() == COMPRESSION_DEFLATED )
    {
        ( $self->{'deflater'}, $status ) = Compress::Raw::Zlib::Deflate->new(
            '-Level'      => $self->desiredCompressionLevel(),
            '-WindowBits' => -MAX_WBITS(),                     # necessary magic
            '-Bufsize'    => $Archive::Zip::ChunkSize,
            @_
        );    # pass additional options
        return _error( 'deflateInit error:', $status )
          unless $status == Z_OK;
        $self->{'chunkHandler'} = $self->can('_deflateChunk');
    }
    elsif ( $self->compressionMethod() == COMPRESSION_DEFLATED
        and $self->desiredCompressionMethod() == COMPRESSION_STORED )
    {
        ( $self->{'inflater'}, $status ) = Compress::Raw::Zlib::Inflate->new(
            '-WindowBits' => -MAX_WBITS(),               # necessary magic
            '-Bufsize'    => $Archive::Zip::ChunkSize,
            @_
        );    # pass additional options
        return _error( 'inflateInit error:', $status )
          unless $status == Z_OK;
        $self->{'chunkHandler'} = $self->can('_inflateChunk');
    }
    elsif ( $self->compressionMethod() == $self->desiredCompressionMethod() ) {
        $self->{'chunkHandler'} = $self->can('_copyChunk');
    }
    else {
        return _error(
            sprintf(
                "Unsupported compression combination: read %d, write %d",
                $self->compressionMethod(),
                $self->desiredCompressionMethod()
            )
        );
    }

    $self->{'readDataRemaining'} =
      ( $self->compressionMethod() == COMPRESSION_STORED )
      ? $self->uncompressedSize()
      : $self->compressedSize();
    $self->{'dataEnded'}  = 0;
    $self->{'readOffset'} = 0;

    return AZ_OK;
}

sub endRead {
    my $self = shift;
    delete $self->{'inflater'};
    delete $self->{'deflater'};
    $self->{'dataEnded'}         = 1;
    $self->{'readDataRemaining'} = 0;
    return AZ_OK;
}

sub readIsDone {
    my $self = shift;
    return ( $self->_dataEnded() or !$self->_readDataRemaining() );
}

sub contents {
    my $self        = shift;
    my $newContents = shift;

    if ( defined($newContents) ) {

        # change our type and call the subclass contents method.
        $self->_become(STRINGMEMBERCLASS);
        return $self->contents( pack( 'C0a*', $newContents ) )
          ;    # in case of Unicode
    }
    else {
        my $oldCompression =
          $self->desiredCompressionMethod(COMPRESSION_STORED);
        my $status = $self->rewindData(@_);
        if ( $status != AZ_OK ) {
            $self->endRead();
            return $status;
        }
        my $retval = '';
        while ( $status == AZ_OK ) {
            my $ref;
            ( $ref, $status ) = $self->readChunk( $self->_readDataRemaining() );

            # did we get it in one chunk?
            if ( length($$ref) == $self->uncompressedSize() ) {
                $retval = $$ref;
            }
            else { $retval .= $$ref }
        }
        $self->desiredCompressionMethod($oldCompression);
        $self->endRead();
        $status = AZ_OK if $status == AZ_STREAM_END;
        $retval = undef unless $status == AZ_OK;
        return wantarray ? ( $retval, $status ) : $retval;
    }
}

sub extractToFileHandle {
    my $self = shift;
    return _error("encryption unsupported") if $self->isEncrypted();
    my $fh = ( ref( $_[0] ) eq 'HASH' ) ? shift->{fileHandle} : shift;
    _binmode($fh);
    my $oldCompression = $self->desiredCompressionMethod(COMPRESSION_STORED);
    my $status         = $self->rewindData(@_);
    $status = $self->_writeData($fh) if $status == AZ_OK;
    $self->desiredCompressionMethod($oldCompression);
    $self->endRead();
    return $status;
}

# write local header and data stream to file handle
sub _writeToFileHandle {
    my $self         = shift;
    my $fh           = shift;
    my $fhIsSeekable = shift;
    my $offset       = shift;

    return _error("no member name given for $self")
      if $self->fileName() eq '';

    $self->{'writeLocalHeaderRelativeOffset'} = $offset;
    $self->{'wasWritten'}                     = 0;

    # Determine if I need to write a data descriptor
    # I need to do this if I can't refresh the header
    # and I don't know compressed size or crc32 fields.
    my $headerFieldsUnknown = (
        ( $self->uncompressedSize() > 0 or $self->compressedSize > 0 )
          and ($self->compressionMethod() == COMPRESSION_STORED
            or $self->desiredCompressionMethod() == COMPRESSION_DEFLATED )
    );

    my $shouldWriteDataDescriptor =
      ( $headerFieldsUnknown and not $fhIsSeekable );

    $self->hasDataDescriptor(1)
      if ($shouldWriteDataDescriptor);

    $self->{'writeOffset'} = 0;

    my $status = $self->rewindData();
    ( $status = $self->_writeLocalFileHeader($fh) )
      if $status == AZ_OK;
    ( $status = $self->_writeData($fh) )
      if $status == AZ_OK;
    if ( $status == AZ_OK ) {
        $self->{'wasWritten'} = 1;
        if ( $self->hasDataDescriptor() ) {
            $status = $self->_writeDataDescriptor($fh);
        }
        elsif ($headerFieldsUnknown) {
            $status = $self->_refreshLocalFileHeader($fh);
        }
    }

    return $status;
}

# Copy my (possibly compressed) data to given file handle.
# Returns C<AZ_OK> on success
sub _writeData {
    my $self    = shift;
    my $writeFh = shift;

    # If symbolic link, just create one if the operating system is Linux, Unix, BSD or VMS
    # TODO: Add checks for other operating systems
    if ( $self->{'isSymbolicLink'} == 1 && $^O eq 'linux' ) {
        my $chunkSize = $Archive::Zip::ChunkSize;
        my ( $outRef, $status ) = $self->readChunk($chunkSize);
        symlink $$outRef, $self->{'newName'};
    } else {
        return AZ_OK if ( $self->uncompressedSize() == 0 );
        my $status;
        my $chunkSize = $Archive::Zip::ChunkSize;
        while ( $self->_readDataRemaining() > 0 ) {
            my $outRef;
            ( $outRef, $status ) = $self->readChunk($chunkSize);
            return $status if ( $status != AZ_OK and $status != AZ_STREAM_END );

            if ( length($$outRef) > 0 ) {
                $self->_print($writeFh, $$outRef)
                  or return _ioError("write error during copy");
            }

            last if $status == AZ_STREAM_END;
        }
        $self->{'compressedSize'} = $self->_writeOffset();
    }
    return AZ_OK;
}

# Return true if I depend on the named file
sub _usesFileNamed {
    return 0;
}

1;
FILE   %abd53b50/Archive/Zip/NewFileMember.pm  �#line 1 "/usr/share/perl5/Archive/Zip/NewFileMember.pm"
package Archive::Zip::NewFileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw ( Archive::Zip::FileMember );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :UTILITY_METHODS
);

# Given a file name, set up for eventual writing.
sub _newFromFileNamed {
    my $class    = shift;
    my $fileName = shift;    # local FS format
    my $newName  = shift;
    $newName = _asZipDirName($fileName) unless defined($newName);
    return undef unless ( stat($fileName) && -r _ && !-d _ );
    my $self = $class->new(@_);
    $self->{'fileName'} = $newName;
    $self->{'externalFileName'}  = $fileName;
    $self->{'compressionMethod'} = COMPRESSION_STORED;
    my @stat = stat(_);
    $self->{'compressedSize'} = $self->{'uncompressedSize'} = $stat[7];
    $self->desiredCompressionMethod(
        ( $self->compressedSize() > 0 )
        ? COMPRESSION_DEFLATED
        : COMPRESSION_STORED
    );
    $self->unixFileAttributes( $stat[2] );
    $self->setLastModFileDateTimeFromUnix( $stat[9] );
    $self->isTextFile( -T _ );
    return $self;
}

sub rewindData {
    my $self = shift;

    my $status = $self->SUPER::rewindData(@_);
    return $status unless $status == AZ_OK;

    return AZ_IO_ERROR unless $self->fh();
    $self->fh()->clearerr();
    $self->fh()->seek( 0, IO::Seekable::SEEK_SET )
      or return _ioError( "rewinding", $self->externalFileName() );
    return AZ_OK;
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ( $self, $dataRef, $chunkSize ) = @_;
    return ( 0, AZ_OK ) unless $chunkSize;
    my $bytesRead = $self->fh()->read( $$dataRef, $chunkSize )
      or return ( 0, _ioError("reading data") );
    return ( $bytesRead, AZ_OK );
}

# If I already exist, extraction is a no-op.
sub extractToFileNamed {
    my $self = shift;
    my $name = shift;    # local FS name
    if ( File::Spec->rel2abs($name) eq
        File::Spec->rel2abs( $self->externalFileName() ) and -r $name )
    {
        return AZ_OK;
    }
    else {
        return $self->SUPER::extractToFileNamed( $name, @_ );
    }
}

1;
FILE   $536ea63b/Archive/Zip/StringMember.pm  �#line 1 "/usr/share/perl5/Archive/Zip/StringMember.pm"
package Archive::Zip::StringMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip::Member );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
);

# Create a new string member. Default is COMPRESSION_STORED.
# Can take a ref to a string as well.
sub _newFromString {
    my $class  = shift;
    my $string = shift;
    my $name   = shift;
    my $self   = $class->new(@_);
    $self->contents($string);
    $self->fileName($name) if defined($name);

    # Set the file date to now
    $self->setLastModFileDateTimeFromUnix( time() );
    $self->unixFileAttributes( $self->DEFAULT_FILE_PERMISSIONS );
    return $self;
}

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;
    delete( $self->{'contents'} );
    return $self->SUPER::_become($newClass);
}

# Get or set my contents. Note that we do not call the superclass
# version of this, because it calls us.
sub contents {
    my $self   = shift;
    my $string = shift;
    if ( defined($string) ) {
        $self->{'contents'} =
          pack( 'C0a*', ( ref($string) eq 'SCALAR' ) ? $$string : $string );
        $self->{'uncompressedSize'} = $self->{'compressedSize'} =
          length( $self->{'contents'} );
        $self->{'compressionMethod'} = COMPRESSION_STORED;
    }
    return $self->{'contents'};
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ( $self, $dataRef, $chunkSize ) = @_;
    $$dataRef = substr( $self->contents(), $self->_readOffset(), $chunkSize );
    return ( length($$dataRef), AZ_OK );
}

1;
FILE   %da46ee73/Archive/Zip/ZipFileMember.pm  5#line 1 "/usr/share/perl5/Archive/Zip/ZipFileMember.pm"
package Archive::Zip::ZipFileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw ( Archive::Zip::FileMember );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

# Create a new Archive::Zip::ZipFileMember
# given a filename and optional open file handle
#
sub _newFromZipFile {
    my $class              = shift;
    my $fh                 = shift;
    my $externalFileName   = shift;
    my $possibleEocdOffset = shift;    # normally 0

    my $self = $class->new(
        'crc32'                     => 0,
        'diskNumberStart'           => 0,
        'localHeaderRelativeOffset' => 0,
        'dataOffset' => 0,    # localHeaderRelativeOffset + header length
        @_
    );
    $self->{'externalFileName'}   = $externalFileName;
    $self->{'fh'}                 = $fh;
    $self->{'possibleEocdOffset'} = $possibleEocdOffset;
    return $self;
}

sub isDirectory {
    my $self = shift;
    return (
        substr( $self->fileName, -1, 1 ) eq '/'
        and
        $self->uncompressedSize == 0
    );
}

# Seek to the beginning of the local header, just past the signature.
# Verify that the local header signature is in fact correct.
# Update the localHeaderRelativeOffset if necessary by adding the possibleEocdOffset.
# Returns status.

sub _seekToLocalHeader {
    my $self          = shift;
    my $where         = shift;    # optional
    my $previousWhere = shift;    # optional

    $where = $self->localHeaderRelativeOffset() unless defined($where);

    # avoid loop on certain corrupt files (from Julian Field)
    return _formatError("corrupt zip file")
      if defined($previousWhere) && $where == $previousWhere;

    my $status;
    my $signature;

    $status = $self->fh()->seek( $where, IO::Seekable::SEEK_SET );
    return _ioError("seeking to local header") unless $status;

    ( $status, $signature ) =
      _readSignature( $self->fh(), $self->externalFileName(),
        LOCAL_FILE_HEADER_SIGNATURE );
    return $status if $status == AZ_IO_ERROR;

    # retry with EOCD offset if any was given.
    if ( $status == AZ_FORMAT_ERROR && $self->{'possibleEocdOffset'} ) {
        $status = $self->_seekToLocalHeader(
            $self->localHeaderRelativeOffset() + $self->{'possibleEocdOffset'},
            $where
        );
        if ( $status == AZ_OK ) {
            $self->{'localHeaderRelativeOffset'} +=
              $self->{'possibleEocdOffset'};
            $self->{'possibleEocdOffset'} = 0;
        }
    }

    return $status;
}

# Because I'm going to delete the file handle, read the local file
# header if the file handle is seekable. If it isn't, I assume that
# I've already read the local header.
# Return ( $status, $self )

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;

    my $status = AZ_OK;

    if ( _isSeekable( $self->fh() ) ) {
        my $here = $self->fh()->tell();
        $status = $self->_seekToLocalHeader();
        $status = $self->_readLocalFileHeader() if $status == AZ_OK;
        $self->fh()->seek( $here, IO::Seekable::SEEK_SET );
        return $status unless $status == AZ_OK;
    }

    delete( $self->{'eocdCrc32'} );
    delete( $self->{'diskNumberStart'} );
    delete( $self->{'localHeaderRelativeOffset'} );
    delete( $self->{'dataOffset'} );

    return $self->SUPER::_become($newClass);
}

sub diskNumberStart {
    shift->{'diskNumberStart'};
}

sub localHeaderRelativeOffset {
    shift->{'localHeaderRelativeOffset'};
}

sub dataOffset {
    shift->{'dataOffset'};
}

# Skip local file header, updating only extra field stuff.
# Assumes that fh is positioned before signature.
sub _skipLocalFileHeader {
    my $self = shift;
    my $header;
    my $bytesRead = $self->fh()->read( $header, LOCAL_FILE_HEADER_LENGTH );
    if ( $bytesRead != LOCAL_FILE_HEADER_LENGTH ) {
        return _ioError("reading local file header");
    }
    my $fileNameLength;
    my $extraFieldLength;
    my $bitFlag;
    (
        undef,    # $self->{'versionNeededToExtract'},
        $bitFlag,
        undef,    # $self->{'compressionMethod'},
        undef,    # $self->{'lastModFileDateTime'},
        undef,    # $crc32,
        undef,    # $compressedSize,
        undef,    # $uncompressedSize,
        $fileNameLength,
        $extraFieldLength
    ) = unpack( LOCAL_FILE_HEADER_FORMAT, $header );

    if ($fileNameLength) {
        $self->fh()->seek( $fileNameLength, IO::Seekable::SEEK_CUR )
          or return _ioError("skipping local file name");
    }

    if ($extraFieldLength) {
        $bytesRead =
          $self->fh()->read( $self->{'localExtraField'}, $extraFieldLength );
        if ( $bytesRead != $extraFieldLength ) {
            return _ioError("reading local extra field");
        }
    }

    $self->{'dataOffset'} = $self->fh()->tell();

    if ( $bitFlag & GPBF_HAS_DATA_DESCRIPTOR_MASK ) {

        # Read the crc32, compressedSize, and uncompressedSize from the
        # extended data descriptor, which directly follows the compressed data.
        #
        # Skip over the compressed file data (assumes that EOCD compressedSize
        # was correct)
        $self->fh()->seek( $self->{'compressedSize'}, IO::Seekable::SEEK_CUR )
          or return _ioError("seeking to extended local header");

        # these values should be set correctly from before.
        my $oldCrc32            = $self->{'eocdCrc32'};
        my $oldCompressedSize   = $self->{'compressedSize'};
        my $oldUncompressedSize = $self->{'uncompressedSize'};

        my $status = $self->_readDataDescriptor();
        return $status unless $status == AZ_OK;

        return _formatError(
            "CRC or size mismatch while skipping data descriptor")
          if ( $oldCrc32 != $self->{'crc32'}
            || $oldUncompressedSize != $self->{'uncompressedSize'} );
    }

    return AZ_OK;
}

# Read from a local file header into myself. Returns AZ_OK if successful.
# Assumes that fh is positioned after signature.
# Note that crc32, compressedSize, and uncompressedSize will be 0 if
# GPBF_HAS_DATA_DESCRIPTOR_MASK is set in the bitFlag.

sub _readLocalFileHeader {
    my $self = shift;
    my $header;
    my $bytesRead = $self->fh()->read( $header, LOCAL_FILE_HEADER_LENGTH );
    if ( $bytesRead != LOCAL_FILE_HEADER_LENGTH ) {
        return _ioError("reading local file header");
    }
    my $fileNameLength;
    my $crc32;
    my $compressedSize;
    my $uncompressedSize;
    my $extraFieldLength;
    (
        $self->{'versionNeededToExtract'}, $self->{'bitFlag'},
        $self->{'compressionMethod'},      $self->{'lastModFileDateTime'},
        $crc32,                            $compressedSize,
        $uncompressedSize,                 $fileNameLength,
        $extraFieldLength
    ) = unpack( LOCAL_FILE_HEADER_FORMAT, $header );

    if ($fileNameLength) {
        my $fileName;
        $bytesRead = $self->fh()->read( $fileName, $fileNameLength );
        if ( $bytesRead != $fileNameLength ) {
            return _ioError("reading local file name");
        }
        $self->fileName($fileName);
    }

    if ($extraFieldLength) {
        $bytesRead =
          $self->fh()->read( $self->{'localExtraField'}, $extraFieldLength );
        if ( $bytesRead != $extraFieldLength ) {
            return _ioError("reading local extra field");
        }
    }

    $self->{'dataOffset'} = $self->fh()->tell();

    if ( $self->hasDataDescriptor() ) {

        # Read the crc32, compressedSize, and uncompressedSize from the
        # extended data descriptor.
        # Skip over the compressed file data (assumes that EOCD compressedSize
        # was correct)
        $self->fh()->seek( $self->{'compressedSize'}, IO::Seekable::SEEK_CUR )
          or return _ioError("seeking to extended local header");

        my $status = $self->_readDataDescriptor();
        return $status unless $status == AZ_OK;
    }
    else {
        return _formatError(
            "CRC or size mismatch after reading data descriptor")
          if ( $self->{'crc32'} != $crc32
            || $self->{'uncompressedSize'} != $uncompressedSize );
    }

    return AZ_OK;
}

# This will read the data descriptor, which is after the end of compressed file
# data in members that that have GPBF_HAS_DATA_DESCRIPTOR_MASK set in their
# bitFlag.
# The only reliable way to find these is to rely on the EOCD compressedSize.
# Assumes that file is positioned immediately after the compressed data.
# Returns status; sets crc32, compressedSize, and uncompressedSize.
sub _readDataDescriptor {
    my $self = shift;
    my $signatureData;
    my $header;
    my $crc32;
    my $compressedSize;
    my $uncompressedSize;

    my $bytesRead = $self->fh()->read( $signatureData, SIGNATURE_LENGTH );
    return _ioError("reading header signature")
      if $bytesRead != SIGNATURE_LENGTH;
    my $signature = unpack( SIGNATURE_FORMAT, $signatureData );

    # unfortunately, the signature appears to be optional.
    if ( $signature == DATA_DESCRIPTOR_SIGNATURE
        && ( $signature != $self->{'crc32'} ) )
    {
        $bytesRead = $self->fh()->read( $header, DATA_DESCRIPTOR_LENGTH );
        return _ioError("reading data descriptor")
          if $bytesRead != DATA_DESCRIPTOR_LENGTH;

        ( $crc32, $compressedSize, $uncompressedSize ) =
          unpack( DATA_DESCRIPTOR_FORMAT, $header );
    }
    else {
        $bytesRead =
          $self->fh()->read( $header, DATA_DESCRIPTOR_LENGTH_NO_SIG );
        return _ioError("reading data descriptor")
          if $bytesRead != DATA_DESCRIPTOR_LENGTH_NO_SIG;

        $crc32 = $signature;
        ( $compressedSize, $uncompressedSize ) =
          unpack( DATA_DESCRIPTOR_FORMAT_NO_SIG, $header );
    }

    $self->{'eocdCrc32'} = $self->{'crc32'}
      unless defined( $self->{'eocdCrc32'} );
    $self->{'crc32'}            = $crc32;
    $self->{'compressedSize'}   = $compressedSize;
    $self->{'uncompressedSize'} = $uncompressedSize;

    return AZ_OK;
}

# Read a Central Directory header. Return AZ_OK on success.
# Assumes that fh is positioned right after the signature.

sub _readCentralDirectoryFileHeader {
    my $self      = shift;
    my $fh        = $self->fh();
    my $header    = '';
    my $bytesRead = $fh->read( $header, CENTRAL_DIRECTORY_FILE_HEADER_LENGTH );
    if ( $bytesRead != CENTRAL_DIRECTORY_FILE_HEADER_LENGTH ) {
        return _ioError("reading central dir header");
    }
    my ( $fileNameLength, $extraFieldLength, $fileCommentLength );
    (
        $self->{'versionMadeBy'},
        $self->{'fileAttributeFormat'},
        $self->{'versionNeededToExtract'},
        $self->{'bitFlag'},
        $self->{'compressionMethod'},
        $self->{'lastModFileDateTime'},
        $self->{'crc32'},
        $self->{'compressedSize'},
        $self->{'uncompressedSize'},
        $fileNameLength,
        $extraFieldLength,
        $fileCommentLength,
        $self->{'diskNumberStart'},
        $self->{'internalFileAttributes'},
        $self->{'externalFileAttributes'},
        $self->{'localHeaderRelativeOffset'}
    ) = unpack( CENTRAL_DIRECTORY_FILE_HEADER_FORMAT, $header );

    $self->{'eocdCrc32'} = $self->{'crc32'};

    if ($fileNameLength) {
        $bytesRead = $fh->read( $self->{'fileName'}, $fileNameLength );
        if ( $bytesRead != $fileNameLength ) {
            _ioError("reading central dir filename");
        }
    }
    if ($extraFieldLength) {
        $bytesRead = $fh->read( $self->{'cdExtraField'}, $extraFieldLength );
        if ( $bytesRead != $extraFieldLength ) {
            return _ioError("reading central dir extra field");
        }
    }
    if ($fileCommentLength) {
        $bytesRead = $fh->read( $self->{'fileComment'}, $fileCommentLength );
        if ( $bytesRead != $fileCommentLength ) {
            return _ioError("reading central dir file comment");
        }
    }

    # NK 10/21/04: added to avoid problems with manipulated headers
    if (    $self->{'uncompressedSize'} != $self->{'compressedSize'}
        and $self->{'compressionMethod'} == COMPRESSION_STORED )
    {
        $self->{'uncompressedSize'} = $self->{'compressedSize'};
    }

    $self->desiredCompressionMethod( $self->compressionMethod() );

    return AZ_OK;
}

sub rewindData {
    my $self = shift;

    my $status = $self->SUPER::rewindData(@_);
    return $status unless $status == AZ_OK;

    return AZ_IO_ERROR unless $self->fh();

    $self->fh()->clearerr();

    # Seek to local file header.
    # The only reason that I'm doing this this way is that the extraField
    # length seems to be different between the CD header and the LF header.
    $status = $self->_seekToLocalHeader();
    return $status unless $status == AZ_OK;

    # skip local file header
    $status = $self->_skipLocalFileHeader();
    return $status unless $status == AZ_OK;

    # Seek to beginning of file data
    $self->fh()->seek( $self->dataOffset(), IO::Seekable::SEEK_SET )
      or return _ioError("seeking to beginning of file data");

    return AZ_OK;
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ( $self, $dataRef, $chunkSize ) = @_;
    return ( 0, AZ_OK ) unless $chunkSize;
    my $bytesRead = $self->fh()->read( $$dataRef, $chunkSize )
      or return ( 0, _ioError("reading data") );
    return ( $bytesRead, AZ_OK );
}

1;
FILE   043563a1/PAR.pm  o�#line 1 "/usr/share/perl5/PAR.pm"
package PAR;
$PAR::VERSION = '1.005';

use 5.006;
use strict;
use warnings;
use Config '%Config';
use Carp qw/croak/;

# If the 'prefork' module is available, we
# register various run-time loaded modules with it.
# That way, there is more shared memory in a forking
# environment.
BEGIN {
    if (eval 'require prefork') {
        prefork->import($_) for qw/
            Archive::Zip
            File::Glob
            File::Spec
            File::Temp
            LWP::Simple
            PAR::Heavy
        /;
        # not including Archive::Unzip::Burst which only makes sense
        # in the context of a PAR::Packer'ed executable anyway.
    }
}

use PAR::SetupProgname;
use PAR::SetupTemp;

#line 311

use vars qw(@PAR_INC);              # explicitly stated PAR library files (preferred)
use vars qw(@PAR_INC_LAST);         # explicitly stated PAR library files (fallback)
use vars qw(%PAR_INC);              # sets {$par}{$file} for require'd modules
use vars qw(@LibCache %LibCache);   # I really miss pseudohash.
use vars qw($LastAccessedPAR $LastTempFile);
use vars qw(@RepositoryObjects);    # If we have PAR::Repository::Client support, we
                                    # put the ::Client objects in here.
use vars qw(@PriorityRepositoryObjects); # repositories which are preferred over local stuff
use vars qw(@UpgradeRepositoryObjects);  # If we have PAR::Repository::Client's in upgrade mode
                                         # put the ::Client objects in here *as well*.
use vars qw(%FileCache);            # The Zip-file file-name-cache
                                    # Layout:
                                    # $FileCache{$ZipObj}{$FileName} = $Member
use vars qw(%ArchivesExtracted);    # Associates archive-zip-object => full extraction path

my $ver  = $Config{version};
my $arch = $Config{archname};
my $progname = $ENV{PAR_PROGNAME} || $0;
my $is_insensitive_fs = (
    -s $progname
        and (-s lc($progname) || -1) == (-s uc($progname) || -1)
        and (-s lc($progname) || -1) == -s $progname
);

# lexical for import(), and _import_foo() functions to control unpar()
my %unpar_options;

# called on "use PAR"
sub import {
    my $class = shift;

    PAR::SetupProgname::set_progname();
    PAR::SetupTemp::set_par_temp_env();

    $progname = $ENV{PAR_PROGNAME} ||= $0;
    $is_insensitive_fs = (-s $progname and (-s lc($progname) || -1) == (-s uc($progname) || -1));

    my @args = @_;
    
    # Insert PAR hook in @INC.
    unshift @INC, \&find_par   unless grep { $_ eq \&find_par }      @INC;
    push @INC, \&find_par_last unless grep { $_ eq \&find_par_last } @INC;

    # process args to use PAR 'foo.par', { opts }, ...;
    foreach my $par (@args) {
        if (ref($par) eq 'HASH') {
            # we have been passed a hash reference
            _import_hash_ref($par);
        }
        elsif ($par =~ /[?*{}\[\]]/) {
           # implement globbing for PAR archives
           require File::Glob;
           foreach my $matched (File::Glob::glob($par)) {
               push @PAR_INC, unpar($matched, undef, undef, 1);
           }
        }
        else {
            # ordinary string argument => file
            push @PAR_INC, unpar($par, undef, undef, 1);
        }
    }

    return if $PAR::__import;
    local $PAR::__import = 1;

    require PAR::Heavy;
    PAR::Heavy::_init_dynaloader();

    # The following code is executed for the case where the
    # running program is itself a PAR archive.
    # ==> run script/main.pl
    if (unpar($progname)) {
        # XXX - handle META.yml here!
        push @PAR_INC, unpar($progname, undef, undef, 1);

        _extract_inc($progname) unless $ENV{PAR_CLEAN};
        if ($LibCache{$progname}) {
          # XXX bad: this us just a good guess
          require File::Spec;
          $ArchivesExtracted{$progname} = File::Spec->catdir($ENV{PAR_TEMP}, 'inc');
        }

        my $zip = $LibCache{$progname};
        my $member = _first_member( $zip,
            "script/main.pl",
            "main.pl",
        );

        if ($progname and !$member) {
            require File::Spec;
            my @path = File::Spec->splitdir($progname);
            my $filename = pop @path;
            $member = _first_member( $zip,
                "script/".$filename,
                "script/".$filename.".pl",
                $filename,
                $filename.".pl",
            )
        }

        # finally take $ARGV[0] as the hint for file to run
        if (defined $ARGV[0] and !$member) {
            $member = _first_member( $zip,
                "script/$ARGV[0]",
                "script/$ARGV[0].pl",
                $ARGV[0],
                "$ARGV[0].pl",
            ) or die qq(PAR.pm: Can't open perl script "$ARGV[0]": No such file or directory);
            shift @ARGV;
        }


        if (!$member) {
            die "Usage: $0 script_file_name.\n";
        }

        _run_member($member);
    }
}


# import() helper for the "use PAR {...};" syntax.
sub _import_hash_ref {
    my $opt = shift;

    # hash slice assignment -- pass all of the options into unpar
    local @unpar_options{keys(%$opt)} = values(%$opt);

    # check for incompatible options:
    if ( exists $opt->{repository} and exists $opt->{file} ) {
        croak("Invalid PAR loading options. Cannot have a 'repository' and 'file' option at the same time.");
    }
    elsif (
        exists $opt->{file}
        and (exists $opt->{install} or exists $opt->{upgrade})
    ) {
        my $e = exists($opt->{install}) ? 'install' : 'upgrade';
        croak("Invalid PAR loading options. Cannot combine 'file' and '$e' options.");
    }
    elsif ( not exists $opt->{repository} and not exists $opt->{file} ) {
        croak("Invalid PAR loading options. Need at least one of 'file' or 'repository' options.");
    }

    # load from file
    if (exists $opt->{file}) {
        croak("Cannot load undefined PAR archive")
          if not defined $opt->{file};

        # for files, we default to loading from PAR archive first
        my $fallback = $opt->{fallback};
        $fallback = 0 if not defined $fallback;
        
        if (not $fallback) {
            # load from this PAR arch preferably
            push @PAR_INC, unpar($opt->{file}, undef, undef, 1);
        }
        else {
            # load from this PAR arch as fallback
            push @PAR_INC_LAST, unpar($opt->{file}, undef, undef, 1);
        }
        
    }
    else {
        # Deal with repositories elsewhere
        my $client = _import_repository($opt);
        return() if not $client;

        if (defined $opt->{run}) {
            # run was specified
            # run the specified script from the repository
            $client->run_script( $opt->{run} );
            return 1;
        }
        
        return 1;
    }

    # run was specified
    # run the specified script from inside the PAR file.
    if (defined $opt->{run}) {
        my $script = $opt->{run};
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();
        
        # XXX - handle META.yml here!
        _extract_inc($opt->{file}) unless $ENV{PAR_CLEAN};
        
        my $zip = $LibCache{$opt->{file}};
        my $member = _first_member( $zip,
            (($script !~ /^script\//) ? ("script/$script", "script/$script.pl") : ()),
            $script,
            "$script.pl",
        );
        
        if (not defined $member) {
            croak("Cannot run script '$script' from PAR file '$opt->{file}'. Script couldn't be found in PAR file.");
        }
        
        _run_member_from_par($member);
    }

    return();
}


# This sub is invoked by _import_hash_ref if a {repository}
# option is found
# Returns the repository client object on success.
sub _import_repository {
    my $opt = shift;
    my $url = $opt->{repository};

    eval "require PAR::Repository::Client; 1;";
    if ($@ or not eval PAR::Repository::Client->VERSION >= 0.04) {
        croak "In order to use the 'use PAR { repository => 'url' };' syntax, you need to install the PAR::Repository::Client module (version 0.04 or later) from CPAN. This module does not seem to be installed as indicated by the following error message: $@";
    }
    
    if ($opt->{upgrade} and not eval PAR::Repository::Client->VERSION >= 0.22) {
        croak "In order to use the 'upgrade' option, you need to install the PAR::Repository::Client module (version 0.22 or later) from CPAN";
    }

    if ($opt->{dependencies} and not eval PAR::Repository::Client->VERSION >= 0.23) {
        croak "In order to use the 'dependencies' option, you need to install the PAR::Repository::Client module (version 0.23 or later) from CPAN";
    }

    my $obj;

    # Support existing clients passed in as objects.
    if (ref($url) and UNIVERSAL::isa($obj, 'PAR::Repository::Client')) {
        $obj = $url;
    }
    else {
        $obj = PAR::Repository::Client->new(
            uri                 => $url,
            auto_install        => $opt->{install},
            auto_upgrade        => $opt->{upgrade},
            static_dependencies => $opt->{dependencies},
        );
    }

    if (exists($opt->{fallback}) and not $opt->{fallback}) {
        push @PriorityRepositoryObjects, $obj; # repository beats local stuff
    } else {
        push @RepositoryObjects, $obj; # local stuff beats repository
    }
    # these are tracked separately so we can check for upgrades early
    push @UpgradeRepositoryObjects, $obj if $opt->{upgrade};

    return $obj;
}

# Given an Archive::Zip obj and a list of files/paths,
# this function returns the Archive::Zip::Member for the
# first of the files found in the ZIP. If none is found,
# returns the empty list.
sub _first_member {
    my $zip = shift;
    foreach my $name (@_) {
        my $member = _cached_member_named($zip, $name);
        return $member if $member;
    }
    return;
}

# Given an Archive::Zip object, this finds the first 
# Archive::Zip member whose file name matches the
# regular expression
sub _first_member_matching {
    my $zip = shift;
    my $regex = shift;

    my $cache = $FileCache{$zip};
    $cache = $FileCache{$zip} = _make_file_cache($zip) if not $cache;

    foreach my $name (keys %$cache) {
      if ($name =~ $regex) {
        return $cache->{$name};
      }
    }

    return();
}


sub _run_member_from_par {
    my $member = shift;
    my $clear_stack = shift;
    my ($fh, $is_new, $filename) = _tempfile($member->crc32String . ".pl");

    if ($is_new) {
        my $file = $member->fileName;
        print $fh "package main;\n";
        print $fh "#line 1 \"$file\"\n";
        $member->extractToFileHandle($fh);
        seek ($fh, 0, 0);
    }

    $ENV{PAR_0} = $filename; # for Pod::Usage
    { do $filename;
      CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
      die $@ if $@;
      exit;
    }
}

sub _run_member {
    my $member = shift;
    my $clear_stack = shift;
    my ($fh, $is_new, $filename) = _tempfile($member->crc32String . ".pl");

    if ($is_new) {
        my $file = $member->fileName;
        print $fh "package main; shift \@INC;\n";
        if (defined &Internals::PAR::CLEARSTACK and $clear_stack) {
            print $fh "Internals::PAR::CLEARSTACK();\n";
        }
        print $fh "#line 1 \"$file\"\n";
        $member->extractToFileHandle($fh);
        seek ($fh, 0, 0);
    }

    unshift @INC, sub { $fh };

    $ENV{PAR_0} = $filename; # for Pod::Usage
    { do 'main';
      CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
      die $@ if $@;
      exit;
    }
}

sub _run_external_file {
    my $filename = shift;
    my $clear_stack = shift;
    require 5.008;
    open my $ffh, '<', $filename
      or die "Can't open perl script \"$filename\": $!";

    my $clearstack = '';
    if (defined &Internals::PAR::CLEARSTACK and $clear_stack) {
        $clear_stack = "Internals::PAR::CLEARSTACK();\n";
    }
    my $string = "package main; shift \@INC;\n$clearstack#line 1 \"$filename\"\n"
                 . do { local $/ = undef; <$ffh> };
    close $ffh;

    open my $fh, '<', \$string
      or die "Can't open file handle to string: $!";

    unshift @INC, sub { $fh };

    $ENV{PAR_0} = $filename; # for Pod::Usage
    { do 'main';
      CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
      die $@ if $@;
      exit;
    }
}

# extract the contents of a .par (or .exe) or any
# Archive::Zip handle to the PAR_TEMP/inc directory.
# returns that directory.
sub _extract_inc {
    my $file_or_azip_handle = shift;
    my $force_extract = shift;
    my $inc = "$PAR::SetupTemp::PARTemp/inc";
    my $dlext = defined($Config{dlext}) ? $Config::Config{dlext} : '';
    my $inc_exists = -d $inc;
    my $is_handle = ref($file_or_azip_handle) && $file_or_azip_handle->isa('Archive::Zip::Archive');

    require File::Spec;

    if (!$inc_exists or $force_extract) {
        for (1 .. 10) { mkdir("$inc.lock", 0755) and last; sleep 1 }
        
        undef $@;
        if (!$is_handle) {
          # First try to unzip the *fast* way.
          eval {
            require Archive::Unzip::Burst;
            Archive::Unzip::Burst::unzip($file_or_azip_handle, $inc)
              and die "Could not unzip '$file_or_azip_handle' into '$inc'. Error: $!";
              die;
          };

          # This means the fast module is there, but didn't work.
          if ($@ =~ /^Could not unzip/) {
            die $@;
          }
        }

        # either failed to load Archive::Unzip::Burst or got an A::Zip handle
        # fallback to slow way.
        if ($is_handle || $@) {
          my $zip;
          if (!$is_handle) {
            open my $fh, '<', $file_or_azip_handle
              or die "Cannot find '$file_or_azip_handle': $!";
            binmode($fh);
            bless($fh, 'IO::File');

            $zip = Archive::Zip->new;
            ( $zip->readFromFileHandle($fh, $file_or_azip_handle) == Archive::Zip::AZ_OK() )
                or die "Read '$file_or_azip_handle' error: $!";
          }
          else {
            $zip = $file_or_azip_handle;
          }

          mkdir($inc) if not -d $inc;

          for ( $zip->memberNames() ) {
              s{^/}{};

              # Skip DLLs (these will be handled by the dynaloader hook) 
              # except for those placed in File::ShareDir directories.
              next if (m{\.\Q$dlext\E[^/]*$} && !m{^lib/auto/share/(dist|module)/}); 

              my $outfile =  File::Spec->catfile($inc, $_);
              next if -e $outfile and not -w _;
              $zip->extractMember($_, "$inc/" . $_);
          }
        }
        
        rmdir("$inc.lock");

        $ArchivesExtracted{$is_handle ? $file_or_azip_handle->fileName() : $file_or_azip_handle} = $inc;
    }

    # add the freshly extracted directories to @INC,
    # but make sure there's no duplicates
    my %inc_exists = map { ($_, 1) } @INC;
    unshift @INC, grep !exists($inc_exists{$_}),
                  grep -d,
                  map File::Spec->catdir($inc, @$_),
                  [ 'lib' ], [ 'arch' ], [ $arch ],
                  [ $ver ], [ $ver, $arch ], [];

    return $inc;
}


# This is the hook placed in @INC for loading PAR's
# before any other stuff in @INC
sub find_par {
    my @args = @_;

    # if there are repositories in upgrade mode, check them
    # first. If so, this is expensive, of course!
    if (@UpgradeRepositoryObjects) {
        my $module = $args[1];
        $module =~ s/\.pm$//;
        $module =~ s/\//::/g;
        foreach my $client (@UpgradeRepositoryObjects) {
            my $local_file = $client->upgrade_module($module);

            # break the require if upgrade_module has been required already
            # to avoid infinite recursion
            if (exists $INC{$args[1]}) {
                # Oh dear. Check for the possible return values of the INC sub hooks in
                # perldoc -f require before trying to understand this.
                # Then, realize that if you pass undef for the file handle, perl (5.8.9)
                # does NOT use the subroutine. Thus the hacky GLOB ref.
                my $line = 1;
                no warnings;
                return (\*I_AM_NOT_HERE, sub {$line ? ($_="1;",$line=0,return(1)) : ($_="",return(0))});
            }

            # Note: This is likely not necessary as the module has been installed
            # into the system by upgrade_module if it was available at all.
            # If it was already loaded, this will not be reached (see return right above).
            # If it could not be loaded from the system and neither found in the repository,
            # we simply want to have the normal error message, too!
            #
            #if ($local_file) {
            #    # XXX load with fallback - is that right?
            #    return _find_par_internals([$PAR_INC_LAST[-1]], @args);
            #}
        }
    }
    my $rv = _find_par_internals(\@PAR_INC, @args);

    return $rv if defined $rv or not @PriorityRepositoryObjects;

    # the repositories that are prefered over locally installed modules
    my $module = $args[1];
    $module =~ s/\.pm$//;
    $module =~ s/\//::/g;
    foreach my $client (@PriorityRepositoryObjects) {
        my $local_file = $client->get_module($module, 0); # 1 == fallback
        if ($local_file) {
            # Not loaded as fallback (cf. PRIORITY) thus look at PAR_INC
            # instead of PAR_INC_LAST
            return _find_par_internals([$PAR_INC[-1]], @args);
        }
    }
    return();
}

# This is the hook placed in @INC for loading PAR's
# AFTER any other stuff in @INC
# It also deals with loading from repositories as a
# fallback-fallback ;)
sub find_par_last {
    my @args = @_;
    # Try the local PAR files first
    my $rv = _find_par_internals(\@PAR_INC_LAST, @args);
    return $rv if defined $rv;

    # No repositories => return
    return $rv if not @RepositoryObjects;

    my $module = $args[1];
    $module =~ s/\.pm$//;
    $module =~ s/\//::/g;
    foreach my $client (@RepositoryObjects) {
        my $local_file = $client->get_module($module, 1); # 1 == fallback
        if ($local_file) {
            # Loaded as fallback thus look at PAR_INC_LAST
            return _find_par_internals([$PAR_INC_LAST[-1]], @args);
        }
    }
    return $rv;
}


# This routine implements loading modules from PARs
# both for loading PARs preferably or as fallback.
# To distinguish the cases, the first parameter should
# be a reference to the corresponding @PAR_INC* array.
sub _find_par_internals {
    my ($INC_ARY, $self, $file, $member_only) = @_;

    my $scheme;
    foreach (@$INC_ARY ? @$INC_ARY : @INC) {
        my $path = $_;
        if ($] < 5.008001) {
            # reassemble from "perl -Ischeme://path" autosplitting
            $path = "$scheme:$path" if !@$INC_ARY
                and $path and $path =~ m!//!
                and $scheme and $scheme =~ /^\w+$/;
            $scheme = $path;
        }
        my $rv = unpar($path, $file, $member_only, 1) or next;
        $PAR_INC{$path}{$file} = 1;
        $INC{$file} = $LastTempFile if (lc($file) =~ /^(?!tk).*\.pm$/);
        return $rv;
    }

    return;
}

sub reload_libs {
    my @par_files = @_;
    @par_files = sort keys %LibCache unless @par_files;

    foreach my $par (@par_files) {
        my $inc_ref = $PAR_INC{$par} or next;
        delete $LibCache{$par};
        delete $FileCache{$par};
        foreach my $file (sort keys %$inc_ref) {
            delete $INC{$file};
            require $file;
        }
    }
}

#sub find_zip_member {
#    my $file = pop;
#
#    foreach my $zip (@LibCache) {
#        my $member = _first_member($zip, $file) or next;
#        return $member;
#    }
#
#    return;
#}

sub read_file {
    my $file = pop;

    foreach my $zip (@LibCache) {
        my $member = _first_member($zip, $file) or next;
        return scalar $member->contents;
    }

    return;
}

sub par_handle {
    my $par = pop;
    return $LibCache{$par};
}

my %escapes;
sub unpar {
    my ($par, $file, $member_only, $allow_other_ext) = @_;
	return if not defined $par;
    my $zip = $LibCache{$par};
    my @rv = $par;

    # a guard against (currently unimplemented) recursion
    return if $PAR::__unpar;
    local $PAR::__unpar = 1;

    unless ($zip) {
        # URL use case ==> download
        if ($par =~ m!^\w+://!) {
            require File::Spec;
            require LWP::Simple;

            # reflector support
            $par .= "pm=$file" if $par =~ /[?&;]/;

            # prepare cache directory
            $ENV{PAR_CACHE} ||= '_par';
            mkdir $ENV{PAR_CACHE}, 0777;
            if (!-d $ENV{PAR_CACHE}) {
                $ENV{PAR_CACHE} = File::Spec->catdir(File::Spec->tmpdir, 'par');
                mkdir $ENV{PAR_CACHE}, 0777;
                return unless -d $ENV{PAR_CACHE};
            }

            # Munge URL into local file name
            # FIXME: This might result in unbelievably long file names!
            # I have run into the file/path length limitations of linux
            # with similar code in PAR::Repository::Client.
            # I suspect this is even worse on Win32.
            # -- Steffen
            my $file = $par;
            if (!%escapes) {
                $escapes{chr($_)} = sprintf("%%%02X", $_) for 0..255;
            }
            {
                use bytes;
                $file =~ s/([^\w\.])/$escapes{$1}/g;
            }

            $file = File::Spec->catfile( $ENV{PAR_CACHE}, $file);
            LWP::Simple::mirror( $par, $file );
            return unless -e $file and -f _;
            $par = $file;
        }
        # Got the .par as a string. (reference to scalar, of course)
        elsif (ref($par) eq 'SCALAR') {
            my ($fh) = _tempfile();
            print $fh $$par;
            $par = $fh;
        }
        # If the par is not a valid .par file name and we're being strict
        # about this, then also check whether "$par.par" exists
        elsif (!(($allow_other_ext or $par =~ /\.par\z/i) and -f $par)) {
            $par .= ".par";
            return unless -f $par;
        }

        require Archive::Zip;
        $zip = Archive::Zip->new;

        my @file;
        if (!ref $par) {
            @file = $par;

            open my $fh, '<', $par;
            binmode($fh);

            $par = $fh;
            bless($par, 'IO::File');
        }

        Archive::Zip::setErrorHandler(sub {});
        my $rv = $zip->readFromFileHandle($par, @file);
        Archive::Zip::setErrorHandler(undef);
        return unless $rv == Archive::Zip::AZ_OK();

        push @LibCache, $zip;
        $LibCache{$_[0]} = $zip;
        $FileCache{$_[0]} = _make_file_cache($zip);

        # only recursive case -- appears to be unused and unimplemented
        foreach my $member ( _cached_members_matching($zip, 
            "^par/(?:$Config{version}/)?(?:$Config{archname}/)?"
        ) ) {
            next if $member->isDirectory;
            my $content = $member->contents();
            next unless $content =~ /^PK\003\004/;
            push @rv, unpar(\$content, undef, undef, 1);
        }
        
        # extract all shlib dlls from the .par to $ENV{PAR_TEMP}
        # Intended to fix problem with Alien::wxWidgets/Wx...
        # NOTE auto/foo/foo.so|dll will get handled by the dynaloader
        # hook, so no need to pull it out here.
        # Allow this to be disabled so caller can do their own caching
        # via import({no_shlib_unpack => 1, file => foo.par})
        if(not $unpar_options{no_shlib_unpack} and defined $ENV{PAR_TEMP}) {
            my @members = _cached_members_matching( $zip,
              qr#^shlib/$Config{archname}/.*\.\Q$Config{dlext}\E(?:\.|$)#
            );
            foreach my $member (@members) {
                next if $member->isDirectory;
                my $member_name = $member->fileName;
                next unless $member_name =~ m{
                        \/([^/]+)$
                    }x
                    or $member_name =~ m{
                        ^([^/]+)$
                    };
                my $extract_name = $1;
                my $dest_name =
                    File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
                # but don't extract it if we've already got one
                $member->extractToFileNamed($dest_name)
                    unless(-e $dest_name);
            }
        }

        # Now push this path into usual library search paths
        my $separator = $Config{path_sep};
        my $tempdir = $ENV{PAR_TEMP};
        foreach my $key (qw(
            LD_LIBRARY_PATH
            LIB_PATH
            LIBRARY_PATH
            PATH
            DYLD_LIBRARY_PATH
        )) {
           if (defined $ENV{$key} and $ENV{$key} ne '') {
               # Check whether it's already in the path. If so, don't
               # append the PAR temp dir in order not to overflow the
               # maximum length for ENV vars.
               $ENV{$key} .= $separator . $tempdir
                 unless grep { $_ eq $tempdir } split $separator, $ENV{$key};
           }
           else {
               $ENV{$key} = $tempdir;
           }
       }
    
    }

    $LastAccessedPAR = $zip;

    return @rv unless defined $file;

    my $member = _first_member($zip,
        "lib/$file",
        "arch/$file",
        "$arch/$file",
        "$ver/$file",
        "$ver/$arch/$file",
        $file,
    ) or return;

    return $member if $member_only;

    my ($fh, $is_new);
    ($fh, $is_new, $LastTempFile) = _tempfile($member->crc32String . ".pm");
    die "Bad Things Happened..." unless $fh;

    if ($is_new) {
        $member->extractToFileHandle($fh);
        seek ($fh, 0, 0);
    }

    return $fh;
}

sub _tempfile {
    my ($fh, $filename);
    if ($ENV{PAR_CLEAN} or !@_) {
        require File::Temp;

        if (defined &File::Temp::tempfile) {
            # under Win32, the file is created with O_TEMPORARY,
            # and will be deleted by the C runtime; having File::Temp
            # delete it has the only effect of giving ugly warnings
            ($fh, $filename) = File::Temp::tempfile(
                DIR     => $PAR::SetupTemp::PARTemp,
                UNLINK  => ($^O ne 'MSWin32' and $^O !~ /hpux/),
            ) or die "Cannot create temporary file: $!";
            binmode($fh);
            return ($fh, 1, $filename);
        }
    }

    require File::Spec;

    # untainting tempfile path
    local $_ = File::Spec->catfile( $PAR::SetupTemp::PARTemp, $_[0] );
    /^(.+)$/ and $filename = $1;

    if (-r $filename) {
        open $fh, '<', $filename or die $!;
        binmode($fh);
        return ($fh, 0, $filename);
    }

    open $fh, '+>', $filename or die $!;
    binmode($fh);
    return ($fh, 1, $filename);
}

# Given an Archive::Zip object, this generates a hash of
#   file_name_in_zip => file object
# and returns a reference to that.
# If we broke the encapsulation of A::Zip::Member and
# accessed $member->{fileName} directly, that would be
# *significantly* faster.
sub _make_file_cache {
    my $zip = shift;
    if (not ref($zip)) {
        croak("_make_file_cache needs an Archive::Zip object as argument.");
    }
    my $cache = {};
    foreach my $member ($zip->members) {
        $cache->{$member->fileName()} = $member;
    }
    return $cache;
}

# given an Archive::Zip object, this finds the cached hash
# of Archive::Zip member names => members,
# and returns all member objects whose file names match
# a regexp
# Without file caching, it just uses $zip->membersMatching
sub _cached_members_matching {
    my $zip = shift;
    my $regex = shift;

    my $cache = $FileCache{$zip};
    $cache = $FileCache{$zip} = _make_file_cache($zip) if not $cache;

    return map {$cache->{$_}}
        grep { $_ =~ $regex }
        keys %$cache;
}

# access named zip file member through cache. Fall
# back to using Archive::Zip (slow)
sub _cached_member_named {
    my $zip = shift;
    my $name = shift;

    my $cache = $FileCache{$zip};
    $cache = $FileCache{$zip} = _make_file_cache($zip) if not $cache;
    return $cache->{$name};
}


# Attempt to clean up the temporary directory if
# --> We're running in clean mode
# --> It's defined
# --> It's an existing directory
# --> It's empty
END {
  if (exists $ENV{PAR_CLEAN} and $ENV{PAR_CLEAN}
      and exists $ENV{PAR_TEMP} and defined $ENV{PAR_TEMP} and -d $ENV{PAR_TEMP}
  ) {
    local($!); # paranoid: ignore potential errors without clobbering a global variable!
    rmdir($ENV{PAR_TEMP});
  }
}

1;

__END__

#line 1249
FILE   b8efc53a/PAR/Dist.pm  yi#line 1 "/usr/share/perl5/PAR/Dist.pm"
package PAR::Dist;
use 5.006;
use strict;
require Exporter;
use vars qw/$VERSION @ISA @EXPORT @EXPORT_OK $DEBUG/;

$VERSION    = '0.48'; # Change version in POD, too!
@ISA        = 'Exporter';
@EXPORT     = qw/
  blib_to_par
  install_par
  uninstall_par
  sign_par
  verify_par
  merge_par
  remove_man
  get_meta
  generate_blib_stub
/;

@EXPORT_OK = qw/
  parse_dist_name
  contains_binaries
/;

$DEBUG = 0;

use Carp qw/carp croak/;
use File::Spec;

#line 142

sub blib_to_par {
    @_ = (path => @_) if @_ == 1;

    my %args = @_;
    require Config;


    # don't use 'my $foo ... if ...' it creates a static variable!
    my $quiet = $args{quiet} || 0;
    my $dist;
    my $path    = $args{path};
    $dist       = File::Spec->rel2abs($args{dist}) if $args{dist};
    my $name    = $args{name};
    my $version = $args{version};
    my $suffix  = $args{suffix} || "$Config::Config{archname}-$Config::Config{version}.par";
    my $cwd;

    if (defined $path) {
        require Cwd;
        $cwd = Cwd::cwd();
        chdir $path;
    }

    _build_blib() unless -d "blib";

    my @files;
    open MANIFEST, ">", File::Spec->catfile("blib", "MANIFEST") or die $!;
    open META, ">", File::Spec->catfile("blib", "META.yml") or die $!;
    
    require File::Find;
    File::Find::find( sub {
        next unless $File::Find::name;
        (-r && !-d) and push ( @files, substr($File::Find::name, 5) );
    } , 'blib' );

    print MANIFEST join(
        "\n",
        '    <!-- accessible as jar:file:///NAME.par!/MANIFEST in compliant browsers -->',
        (sort @files),
        q(    # <html><body onload="var X=document.body.innerHTML.split(/\n/);var Y='<iframe src=&quot;META.yml&quot; style=&quot;float:right;height:40%;width:40%&quot;></iframe><ul>';for(var x in X){if(!X[x].match(/^\s*#/)&&X[x].length)Y+='<li><a href=&quot;'+X[x]+'&quot;>'+X[x]+'</a>'}document.body.innerHTML=Y">)
    );
    close MANIFEST;

    # if MYMETA.yml exists, that takes precedence over META.yml
    my $meta_file_name = "META.yml";
    my $mymeta_file_name = "MYMETA.yml";
    $meta_file_name = -s $mymeta_file_name ? $mymeta_file_name : $meta_file_name;
    if (open(OLD_META, $meta_file_name)) {
        while (<OLD_META>) {
            if (/^distribution_type:/) {
                print META "distribution_type: par\n";
            }
            else {
                print META $_;
            }

            if (/^name:\s+(.*)/) {
                $name ||= $1;
                $name =~ s/::/-/g;
            }
            elsif (/^version:\s+.*Module::Build::Version/) {
                while (<OLD_META>) {
                    /^\s+original:\s+(.*)/ or next;
                    $version ||= $1;
                    last;
                }
            }
            elsif (/^version:\s+(.*)/) {
                $version ||= $1;
            }
        }
        close OLD_META;
        close META;
    }
    
    if ((!$name or !$version) and open(MAKEFILE, "Makefile")) {
        while (<MAKEFILE>) {
            if (/^DISTNAME\s+=\s+(.*)$/) {
                $name ||= $1;
            }
            elsif (/^VERSION\s+=\s+(.*)$/) {
                $version ||= $1;
            }
        }
    }

    if (not defined($name) or not defined($version)) {
        # could not determine name or version. Error.
        my $what;
        if (not defined $name) {
            $what = 'name';
            $what .= ' and version' if not defined $version;
        }
        elsif (not defined $version) {
            $what = 'version';
        }
        
        carp("I was unable to determine the $what of the PAR distribution. Please create a Makefile or META.yml file from which we can infer the information or just specify the missing information as an option to blib_to_par.");
        return();
    }
    
    $name =~ s/\s+$//;
    $version =~ s/\s+$//;

    my $file = "$name-$version-$suffix";
    unlink $file if -f $file;

    print META << "YAML" if fileno(META);
name: $name
version: $version
build_requires: {}
conflicts: {}
dist_name: $file
distribution_type: par
dynamic_config: 0
generated_by: 'PAR::Dist version $PAR::Dist::VERSION'
license: unknown
YAML
    close META;

    mkdir('blib', 0777);
    chdir('blib');
    require Cwd;
    my $zipoutfile = File::Spec->catfile(File::Spec->updir, $file);
    _zip(dist => $zipoutfile);
    chdir(File::Spec->updir);

    unlink File::Spec->catfile("blib", "MANIFEST");
    unlink File::Spec->catfile("blib", "META.yml");

    $dist ||= File::Spec->catfile($cwd, $file) if $cwd;

    if ($dist and $file ne $dist) {
        if ( File::Copy::copy($file, $dist) ) {
          unlink $file;
        } else {
          die "Cannot copy $file: $!";
        }

        $file = $dist;
    }

    my $pathname = File::Spec->rel2abs($file);
    if ($^O eq 'MSWin32') {
        $pathname =~ s!\\!/!g;
        $pathname =~ s!:!|!g;
    };
    print << "." if !$quiet;
Successfully created binary distribution '$file'.
Its contents are accessible in compliant browsers as:
    jar:file://$pathname!/MANIFEST
.

    chdir $cwd if $cwd;
    return $file;
}

sub _build_blib {
    if (-e 'Build') {
        _system_wrapper($^X, "Build");
    }
    elsif (-e 'Makefile') {
        _system_wrapper($Config::Config{make});
    }
    elsif (-e 'Build.PL') {
        _system_wrapper($^X, "Build.PL");
        _system_wrapper($^X, "Build");
    }
    elsif (-e 'Makefile.PL') {
        _system_wrapper($^X, "Makefile.PL");
        _system_wrapper($Config::Config{make});
    }
}

#line 401

sub install_par {
    my %args = &_args;
    _install_or_uninstall(%args, action => 'install');
}

#line 422

sub uninstall_par {
    my %args = &_args;
    _install_or_uninstall(%args, action => 'uninstall');
}

sub _install_or_uninstall {
    my %args = &_args;
    my $name = $args{name};
    my $action = $args{action};

    my %ENV_copy = %ENV;
    $ENV{PERL_INSTALL_ROOT} = $args{prefix} if defined $args{prefix};

    require Cwd;
    my $old_dir = Cwd::cwd();
    
    my ($dist, $tmpdir) = _unzip_to_tmpdir( dist => $args{dist}, subdir => 'blib' );

    if ( open (META, File::Spec->catfile('blib', 'META.yml')) ) {
        while (<META>) {
            next unless /^name:\s+(.*)/;
            $name = $1;
            $name =~ s/\s+$//;
            last;
        }
        close META;
    }
    return if not defined $name or $name eq '';

    if (-d 'script') {
        require ExtUtils::MY;
        foreach my $file (glob("script/*")) {
            next unless -T $file;
            ExtUtils::MY->fixin($file);
            chmod(0555, $file);
        }
    }

    $name =~ s{::|-}{/}g;
    require ExtUtils::Install;

    if ($action eq 'install') {
        my $target = _installation_target( File::Spec->curdir, $name, \%args );
        my $custom_targets = $args{custom_targets} || {};
        $target->{$_} = $custom_targets->{$_} foreach keys %{$custom_targets};
        
        my $uninstall_shadows = $args{uninstall_shadows};
        my $verbose = $args{verbose};
        ExtUtils::Install::install($target, $verbose, 0, $uninstall_shadows);
    }
    elsif ($action eq 'uninstall') {
        require Config;
        my $verbose = $args{verbose};
        ExtUtils::Install::uninstall(
            $args{packlist_read}||"$Config::Config{installsitearch}/auto/$name/.packlist",
            $verbose
        );
    }

    %ENV = %ENV_copy;

    chdir($old_dir);
    File::Path::rmtree([$tmpdir]);

    return 1;
}

# Returns the default installation target as used by
# ExtUtils::Install::install(). First parameter should be the base
# directory containing the blib/ we're installing from.
# Second parameter should be the name of the distribution for the packlist
# paths. Third parameter may be a hash reference with user defined keys for
# the target hash. In fact, any contents that do not start with 'inst_' are
# skipped.
sub _installation_target {
    require Config;
    my $dir = shift;
    my $name = shift;
    my $user = shift || {};

    # accepted sources (and user overrides)
    my %sources = (
      inst_lib => File::Spec->catdir($dir,"blib","lib"),
      inst_archlib => File::Spec->catdir($dir,"blib","arch"),
      inst_bin => File::Spec->catdir($dir,'blib','bin'),
      inst_script => File::Spec->catdir($dir,'blib','script'),
      inst_man1dir => File::Spec->catdir($dir,'blib','man1'),
      inst_man3dir => File::Spec->catdir($dir,'blib','man3'),
      packlist_read => 'read',
      packlist_write => 'write',
    );


    my $par_has_archlib = _directory_not_empty( $sources{inst_archlib} );

    # default targets
    my $target = {
       read => $Config::Config{sitearchexp}."/auto/$name/.packlist",
       write => $Config::Config{installsitearch}."/auto/$name/.packlist",
       $sources{inst_lib} =>
            ($par_has_archlib
             ? $Config::Config{installsitearch}
             : $Config::Config{installsitelib}),
       $sources{inst_archlib}   => $Config::Config{installsitearch},
       $sources{inst_bin}       => $Config::Config{installbin} ,
       $sources{inst_script}    => $Config::Config{installscript},
       $sources{inst_man1dir}   => $Config::Config{installman1dir},
       $sources{inst_man3dir}   => $Config::Config{installman3dir},
    };
    
    # Included for future support for ${flavour}perl external lib installation
#    if ($Config::Config{flavour_perl}) {
#        my $ext = File::Spec->catdir($dir, 'blib', 'ext');
#        # from => to
#        $sources{inst_external_lib}    = File::Spec->catdir($ext, 'lib');
#        $sources{inst_external_bin}    = File::Spec->catdir($ext, 'bin');
#        $sources{inst_external_include} = File::Spec->catdir($ext, 'include');
#        $sources{inst_external_src}    = File::Spec->catdir($ext, 'src');
#        $target->{ $sources{inst_external_lib} }     = $Config::Config{flavour_install_lib};
#        $target->{ $sources{inst_external_bin} }     = $Config::Config{flavour_install_bin};
#        $target->{ $sources{inst_external_include} } = $Config::Config{flavour_install_include};
#        $target->{ $sources{inst_external_src} }     = $Config::Config{flavour_install_src};
#    }
    
    # insert user overrides
    foreach my $key (keys %$user) {
        my $value = $user->{$key};
        if (not defined $value and $key ne 'packlist_read' and $key ne 'packlist_write') {
          # undef means "remove"
          delete $target->{ $sources{$key} };
        }
        elsif (exists $sources{$key}) {
          # overwrite stuff, don't let the user create new entries
          $target->{ $sources{$key} } = $value;
        }
    }

    # apply the automatic inst_lib => inst_archlib conversion again
    # if the user asks for it and there is an archlib in the .par
    if ($user->{auto_inst_lib_conversion} and $par_has_archlib) {
      $target->{inst_lib} = $target->{inst_archlib};
    }

    return $target;
}

sub _directory_not_empty {
    require File::Find;
    my($dir) = @_;
    my $files = 0;
    File::Find::find(sub {
        return if $_ eq ".exists";
        if (-f) {
            $File::Find::prune++;
            $files = 1;
            }
    }, $dir);
    return $files;
}

#line 589

sub sign_par {
    my %args = &_args;
    _verify_or_sign(%args, action => 'sign');
}

#line 604

sub verify_par {
    my %args = &_args;
    $! = _verify_or_sign(%args, action => 'verify');
    return ( $! == Module::Signature::SIGNATURE_OK() );
}

#line 633

sub merge_par {
    my $base_par = shift;
    my @additional_pars = @_;
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Find;

    # parameter checking
    if (not defined $base_par) {
        croak "First argument to merge_par() must be the .par archive to modify.";
    }

    if (not -f $base_par or not -r _ or not -w _) {
        croak "'$base_par' is not a file or you do not have enough permissions to read and modify it.";
    }
    
    foreach (@additional_pars) {
        if (not -f $_ or not -r _) {
            croak "'$_' is not a file or you do not have enough permissions to read it.";
        }
    }

    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $base_par, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');

    # move the META.yml to the (main) temp. dir.
    my $main_meta_file = File::Spec->catfile($base_dir, 'META.yml');
    File::Copy::move(
        File::Spec->catfile($blibdir, 'META.yml'),
        $main_meta_file
    );
    # delete (incorrect) MANIFEST
    unlink File::Spec->catfile($blibdir, 'MANIFEST');

    # extract additional pars and merge    
    foreach my $par (@additional_pars) {
        # restore original directory because the par path
        # might have been relative!
        chdir($old_cwd);
        (undef, my $add_dir) = _unzip_to_tmpdir(
            dist => $par
        );

        # merge the meta (at least the provides info) into the main meta.yml
        my $meta_file = File::Spec->catfile($add_dir, 'META.yml');
        if (-f $meta_file) {
          _merge_meta($main_meta_file, $meta_file);
        }

        my @files;
        my @dirs;
        # I hate File::Find
        # And I hate writing portable code, too.
        File::Find::find(
            {wanted =>sub {
                my $file = $File::Find::name;
                push @files, $file if -f $file;
                push @dirs, $file if -d _;
            }},
            $add_dir
        );
        my ($vol, $subdir, undef) = File::Spec->splitpath( $add_dir, 1);
        my @dir = File::Spec->splitdir( $subdir );
    
        # merge directory structure
        foreach my $dir (@dirs) {
            my ($v, $d, undef) = File::Spec->splitpath( $dir, 1 );
            my @d = File::Spec->splitdir( $d );
            shift @d foreach @dir; # remove tmp dir from path
            my $target = File::Spec->catdir( $blibdir, @d );
            mkdir($target);
        }

        # merge files
        foreach my $file (@files) {
            my ($v, $d, $f) = File::Spec->splitpath( $file );
            my @d = File::Spec->splitdir( $d );
            shift @d foreach @dir; # remove tmp dir from path
            my $target = File::Spec->catfile(
                File::Spec->catdir( $blibdir, @d ),
                $f
            );
            File::Copy::copy($file, $target)
              or die "Could not copy '$file' to '$target': $!";
            
        }
        chdir($old_cwd);
        File::Path::rmtree([$add_dir]);
    }
    
    # delete (copied) MANIFEST and META.yml
    unlink File::Spec->catfile($blibdir, 'MANIFEST');
    unlink File::Spec->catfile($blibdir, 'META.yml');
    
    chdir($base_dir);
    my $resulting_par_file = Cwd::abs_path(blib_to_par(quiet => 1));
    chdir($old_cwd);
    File::Copy::move($resulting_par_file, $base_par);
    
    File::Path::rmtree([$base_dir]);
}


sub _merge_meta {
  my $meta_orig_file = shift;
  my $meta_extra_file = shift;
  return() if not defined $meta_orig_file or not -f $meta_orig_file;
  return 1 if not defined $meta_extra_file or not -f $meta_extra_file;

  my $yaml_functions = _get_yaml_functions();

  die "Cannot merge META.yml files without a YAML reader/writer"
    if !exists $yaml_functions->{LoadFile}
    or !exists $yaml_functions->{DumpFile};

  my $orig_meta  = $yaml_functions->{LoadFile}->($meta_orig_file);
  my $extra_meta = $yaml_functions->{LoadFile}->($meta_extra_file);

  # I seem to remember there was this incompatibility between the different
  # YAML implementations with regards to "document" handling:
  my $orig_tree  = (ref($orig_meta) eq 'ARRAY' ? $orig_meta->[0] : $orig_meta);
  my $extra_tree = (ref($extra_meta) eq 'ARRAY' ? $extra_meta->[0] : $extra_meta);

  _merge_provides($orig_tree, $extra_tree);
  _merge_requires($orig_tree, $extra_tree);
  
  $yaml_functions->{DumpFile}->($meta_orig_file, $orig_meta);

  return 1;
}

# merge the two-level provides sections of META.yml
sub _merge_provides {
  my $orig_hash  = shift;
  my $extra_hash = shift;

  return() if not exists $extra_hash->{provides};
  $orig_hash->{provides} ||= {};

  my $orig_provides  = $orig_hash->{provides};
  my $extra_provides = $extra_hash->{provides};

  # two level clone is enough wrt META spec 1.4
  # overwrite the original provides since we're also overwriting the files.
  foreach my $module (keys %$extra_provides) {
    my $extra_mod_hash = $extra_provides->{$module};
    my %mod_hash;
    $mod_hash{$_} = $extra_mod_hash->{$_} for keys %$extra_mod_hash;
    $orig_provides->{$module} = \%mod_hash;
  }
}

# merge the single-level requires-like sections of META.yml
sub _merge_requires {
  my $orig_hash  = shift;
  my $extra_hash = shift;

  foreach my $type (qw(requires build_requires configure_requires recommends)) {
    next if not exists $extra_hash->{$type};
    $orig_hash->{$type} ||= {};
    
    # one level clone is enough wrt META spec 1.4
    foreach my $module (keys %{ $extra_hash->{$type} }) {
      # FIXME there should be a version comparison here, BUT how are we going to do that without a guaranteed version.pm?
      $orig_hash->{$type}{$module} = $extra_hash->{$type}{$module}; # assign version and module name
    }
  }
}

#line 822

sub remove_man {
    my %args = &_args;
    my $par = $args{dist};
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Find;

    # parameter checking
    if (not defined $par) {
        croak "First argument to remove_man() must be the .par archive to modify.";
    }

    if (not -f $par or not -r _ or not -w _) {
        croak "'$par' is not a file or you do not have enough permissions to read and modify it.";
    }
    
    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $par, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');

    # move the META.yml to the (main) temp. dir.
    File::Copy::move(
        File::Spec->catfile($blibdir, 'META.yml'),
        File::Spec->catfile($base_dir, 'META.yml')
    );
    # delete (incorrect) MANIFEST
    unlink File::Spec->catfile($blibdir, 'MANIFEST');

    opendir DIRECTORY, 'blib' or die $!;
    my @dirs = grep { /^blib\/(?:man\d*|html)$/ }
               grep { -d $_ }
               map  { File::Spec->catfile('blib', $_) }
               readdir DIRECTORY;
    close DIRECTORY;
    
    File::Path::rmtree(\@dirs);
    
    chdir($base_dir);
    my $resulting_par_file = Cwd::abs_path(blib_to_par());
    chdir($old_cwd);
    File::Copy::move($resulting_par_file, $par);
    
    File::Path::rmtree([$base_dir]);
}


#line 888

sub get_meta {
    my %args = &_args;
    my $dist = $args{dist};
    return undef if not defined $dist or not -r $dist;
    require Cwd;
    require File::Path;

    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $dist, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');

    my $meta = File::Spec->catfile($blibdir, 'META.yml');

    if (not -r $meta) {
        return undef;
    }
    
    open FH, '<', $meta
      or die "Could not open file '$meta' for reading: $!";
    
    local $/ = undef;
    my $meta_text = <FH>;
    close FH;
    
    chdir($old_cwd);
    
    File::Path::rmtree([$base_dir]);
    
    return $meta_text;
}



sub _unzip {
    my %args = &_args;
    my $dist = $args{dist};
    my $path = $args{path} || File::Spec->curdir;
    return unless -f $dist;

    # Try fast unzipping first
    if (eval { require Archive::Unzip::Burst; 1 }) {
        my $return = !Archive::Unzip::Burst::unzip($dist, $path);
        return if $return; # true return value == error (a la system call)
    }
    # Then slow unzipping
    if (eval { require Archive::Zip; 1 }) {
        my $zip = Archive::Zip->new;
        local %SIG;
        $SIG{__WARN__} = sub { print STDERR $_[0] unless $_[0] =~ /\bstat\b/ };
        return unless $zip->read($dist) == Archive::Zip::AZ_OK()
                  and $zip->extractTree('', "$path/") == Archive::Zip::AZ_OK();
    }
    # Then fall back to the system
    else {
        undef $!;
        if (_system_wrapper(unzip => $dist, '-d', $path)) {
            die "Failed to unzip '$dist' to path '$path': Could neither load "
                . "Archive::Zip nor (successfully) run the system 'unzip' (unzip said: $!)";
        }
    }

    return 1;
}

sub _zip {
    my %args = &_args;
    my $dist = $args{dist};

    if (eval { require Archive::Zip; 1 }) {
        my $zip = Archive::Zip->new;
        $zip->addTree( File::Spec->curdir, '' );
        $zip->writeToFileNamed( $dist ) == Archive::Zip::AZ_OK() or die $!;
    }
    else {
        undef $!;
        if (_system_wrapper(qw(zip -r), $dist, File::Spec->curdir)) {
            die "Failed to zip '" .File::Spec->curdir(). "' to '$dist': Could neither load "
                . "Archive::Zip nor (successfully) run the system 'zip' (zip said: $!)";
        }
    }
    return 1;
}


# This sub munges the arguments to most of the PAR::Dist functions
# into a hash. On the way, it downloads PAR archives as necessary, etc.
sub _args {
    # default to the first .par in the CWD
    if (not @_) {
        @_ = (glob('*.par'))[0];
    }

    # single argument => it's a distribution file name or URL
    @_ = (dist => @_) if @_ == 1;

    my %args = @_;
    $args{name} ||= $args{dist};

    # If we are installing from an URL, we want to munge the
    # distribution name so that it is in form "Module-Name"
    if (defined $args{name}) {
        $args{name} =~ s/^\w+:\/\///;
        my @elems = parse_dist_name($args{name});
        # @elems is name, version, arch, perlversion
        if (defined $elems[0]) {
            $args{name} = $elems[0];
        }
        else {
            $args{name} =~ s/^.*\/([^\/]+)$/$1/;
            $args{name} =~ s/^([0-9A-Za-z_-]+)-\d+\..+$/$1/;
        }
    }

    # append suffix if there is none
    if ($args{dist} and not $args{dist} =~ /\.[a-zA-Z_][^.]*$/) {
        require Config;
        my $suffix = $args{suffix};
        $suffix ||= "$Config::Config{archname}-$Config::Config{version}.par";
        $args{dist} .= "-$suffix";
    }

    # download if it's an URL
    if ($args{dist} and $args{dist} =~ m!^\w+://!) {
        $args{dist} = _fetch(dist => $args{dist})
    }

    return %args;
}


# Download PAR archive, but only if necessary (mirror!)
my %escapes;
sub _fetch {
    my %args = @_;

    if ($args{dist} =~ s/^file:\/\///) {
      return $args{dist} if -e $args{dist};
      return;
    }
    require LWP::Simple;

    $ENV{PAR_TEMP} ||= File::Spec->catdir(File::Spec->tmpdir, 'par');
    mkdir $ENV{PAR_TEMP}, 0777;
    %escapes = map { chr($_) => sprintf("%%%02X", $_) } 0..255 unless %escapes;

    $args{dist} =~ s{^cpan://((([a-zA-Z])[a-zA-Z])[-_a-zA-Z]+)/}
                    {http://www.cpan.org/modules/by-authors/id/\U$3/$2/$1\E/};

    my $file = $args{dist};
    $file =~ s/([^\w\.])/$escapes{$1}/g;
    $file = File::Spec->catfile( $ENV{PAR_TEMP}, $file);
    my $rc = LWP::Simple::mirror( $args{dist}, $file );

    if (!LWP::Simple::is_success($rc) and $rc != 304) {
        die "Error $rc: ", LWP::Simple::status_message($rc), " ($args{dist})\n";
    }

    return $file if -e $file;
    return;
}

sub _verify_or_sign {
    my %args = &_args;

    require File::Path;
    require Module::Signature;
    die "Module::Signature version 0.25 required"
      unless Module::Signature->VERSION >= 0.25;

    require Cwd;
    my $cwd = Cwd::cwd();
    my $action = $args{action};
    my ($dist, $tmpdir) = _unzip_to_tmpdir($args{dist});
    $action ||= (-e 'SIGNATURE' ? 'verify' : 'sign');

    if ($action eq 'sign') {
        open FH, '>SIGNATURE' unless -e 'SIGNATURE';
        open FH, 'MANIFEST' or die $!;

        local $/;
        my $out = <FH>;
        if ($out !~ /^SIGNATURE(?:\s|$)/m) {
            $out =~ s/^(?!\s)/SIGNATURE\n/m;
            open FH, '>MANIFEST' or die $!;
            print FH $out;
        }
        close FH;

        $args{overwrite} = 1 unless exists $args{overwrite};
        $args{skip}      = 0 unless exists $args{skip};
    }

    my $rv = Module::Signature->can($action)->(%args);
    _zip(dist => $dist) if $action eq 'sign';
    File::Path::rmtree([$tmpdir]);

    chdir($cwd);
    return $rv;
}

sub _unzip_to_tmpdir {
    my %args = &_args;

    require File::Temp;

    my $dist   = File::Spec->rel2abs($args{dist});
    my $tmpdirname = File::Spec->catdir(File::Spec->tmpdir, "parXXXXX");
    my $tmpdir = File::Temp::mkdtemp($tmpdirname)        
      or die "Could not create temporary directory from template '$tmpdirname': $!";
    my $path = $tmpdir;
    $path = File::Spec->catdir($tmpdir, $args{subdir}) if defined $args{subdir};
    _unzip(dist => $dist, path => $path);

    chdir $tmpdir;
    return ($dist, $tmpdir);
}



#line 1136

sub parse_dist_name {
    my $file = shift;
    return(undef, undef, undef, undef) if not defined $file;

    (undef, undef, $file) = File::Spec->splitpath($file);
    
    my $version = qr/v?(?:\d+(?:_\d+)?|\d*(?:\.\d+(?:_\d+)?)+)/;
    $file =~ s/\.(?:par|tar\.gz|tar)$//i;
    my @elem = split /-/, $file;
    my (@dn, $dv, @arch, $pv);
    while (@elem) {
        my $e = shift @elem;
        if (
            $e =~ /^$version$/o
            and not(# if not next token also a version
                    # (assumes an arch string doesnt start with a version...)
                @elem and $elem[0] =~ /^$version$/o
            )
        ) {
            $dv = $e;
            last;
        }
        push @dn, $e;
    }
    
    my $dn;
    $dn = join('-', @dn) if @dn;

    if (not @elem) {
        return( $dn, $dv, undef, undef);
    }

    while (@elem) {
        my $e = shift @elem;
        if ($e =~ /^$version|any_version$/) {
            $pv = $e;
            last;
        }
        push @arch, $e;
    }

    my $arch;
    $arch = join('-', @arch) if @arch;

    return($dn, $dv, $arch, $pv);
}

#line 1212

sub generate_blib_stub {
    my %args = &_args;
    my $dist = $args{dist};
    require Config;
    
    my $name    = $args{name};
    my $version = $args{version};
    my $suffix  = $args{suffix};

    my ($parse_name, $parse_version, $archname, $perlversion)
      = parse_dist_name($dist);
    
    $name ||= $parse_name;
    $version ||= $parse_version;
    $suffix = "$archname-$perlversion"
      if (not defined $suffix or $suffix eq '')
         and $archname and $perlversion;
    
    $suffix ||= "$Config::Config{archname}-$Config::Config{version}";
    if ( grep { not defined $_ } ($name, $version, $suffix) ) {
        warn "Could not determine distribution meta information from distribution name '$dist'";
        return();
    }
    $suffix =~ s/\.par$//;

    if (not -f 'META.yml') {
        open META, '>', 'META.yml'
          or die "Could not open META.yml file for writing: $!";
        print META << "YAML" if fileno(META);
name: $name
version: $version
build_requires: {}
conflicts: {}
dist_name: $name-$version-$suffix.par
distribution_type: par
dynamic_config: 0
generated_by: 'PAR::Dist version $PAR::Dist::VERSION'
license: unknown
YAML
        close META;
    }

    mkdir('blib');
    mkdir(File::Spec->catdir('blib', 'lib'));
    mkdir(File::Spec->catdir('blib', 'script'));

    return 1;
}


#line 1280

sub contains_binaries {
    require File::Find;
    my %args = &_args;
    my $dist = $args{dist};
    return undef if not defined $dist or not -r $dist;
    require Cwd;
    require File::Path;

    # The unzipping will change directories. Remember old dir.
    my $old_cwd = Cwd::cwd();
    
    # Unzip the base par to a temp. dir.
    (undef, my $base_dir) = _unzip_to_tmpdir(
        dist => $dist, subdir => 'blib'
    );
    my $blibdir = File::Spec->catdir($base_dir, 'blib');
    my $archdir = File::Spec->catdir($blibdir, 'arch');

    my $found = 0;

    File::Find::find(
      sub {
        $found++ if -f $_ and not /^\.exists$/;
      },
      $archdir
    );

    chdir($old_cwd);
    
    File::Path::rmtree([$base_dir]);
    
    return $found ? 1 : 0;
}

sub _system_wrapper {
  if ($DEBUG) {
    Carp::cluck("Running system call '@_' from:");
  }
  return system(@_);
}

# stolen from Module::Install::Can
# very much internal and subject to change or removal
sub _MI_can_run {
  require ExtUtils::MakeMaker;
  my ($cmd) = @_;

  my $_cmd = $cmd;
  return $_cmd if (-x $_cmd or $_cmd = MM->maybe_command($_cmd));

  for my $dir ((split /$Config::Config{path_sep}/, $ENV{PATH}), '.') {
    my $abs = File::Spec->catfile($dir, $cmd);
    return $abs if (-x $abs or $abs = MM->maybe_command($abs));
  }

  return;
}


# Tries to load any YAML reader writer I know of
# returns nothing on failure or hash reference containing
# a subset of Load, Dump, LoadFile, DumpFile
# entries with sub references on success.
sub _get_yaml_functions {
  # reasoning for the ranking here:
  # - XS is the de-facto standard nowadays.
  # - YAML.pm is slow and aging
  # - syck is fast and reasonably complete
  # - Tiny is only a very small subset
  # - Parse... is only a reader and only deals with the same subset as ::Tiny
  my @modules = qw(YAML::XS YAML YAML::Tiny YAML::Syck Parse::CPAN::Meta);

  my %yaml_functions;
  foreach my $module (@modules) {
    eval "require $module;";
    if (!$@) {
      warn "PAR::Dist testers/debug info: Using '$module' as YAML implementation" if $DEBUG;
      foreach my $sub (qw(Load Dump LoadFile DumpFile)) {
        no strict 'refs';
        my $subref = *{"${module}::$sub"}{CODE};
        if (defined $subref and ref($subref) eq 'CODE') {
          $yaml_functions{$sub} = $subref;
        }
      }
      $yaml_functions{yaml_provider} = $module;
      last;
    }
  } # end foreach module candidates
  if (not keys %yaml_functions) {
    warn "Cannot find a working YAML reader/writer implementation. Tried to load all of '@modules'";
  }
  return(\%yaml_functions);
}

sub _check_tools {
  my $tools = _get_yaml_functions();
  if ($DEBUG) {
    foreach (qw/Load Dump LoadFile DumpFile/) {
      warn "No YAML support for $_ found.\n" if not defined $tools->{$_};
    }
  }

  $tools->{zip} = undef;
  # A::Zip 1.28 was a broken release...
  if (eval {require Archive::Zip; 1;} and $Archive::Zip::VERSION ne '1.28') {
    warn "Using Archive::Zip as ZIP tool.\n" if $DEBUG;
    $tools->{zip} = 'Archive::Zip';
  }
  elsif (_MI_can_run("zip") and _MI_can_run("unzip")) {
    warn "Using zip/unzip as ZIP tool.\n" if $DEBUG;
    $tools->{zip} = 'zip';
  }
  else {
    warn "Found neither Archive::Zip (version != 1.28) nor ZIP/UNZIP as valid ZIP tools.\n" if $DEBUG;
    $tools->{zip} = undef;
  }

  return $tools;
}

1;

#line 1429
FILE   a9ae78ee/PAR/Filter.pm  l#line 1 "/usr/share/perl5/PAR/Filter.pm"
package PAR::Filter;
use 5.006;
use strict;
use warnings;
our $VERSION = '0.03';

#line 64

sub new {
    my $class = shift;
    require "PAR/Filter/$_.pm" foreach @_;
    bless(\@_, $class);
}

sub apply {
    my ($self, $ref, $name) = @_;
    my $filename = $name || '-e';

    if (!ref $ref) {
	$name ||= $filename = $ref;
	local $/;
	open my $fh, $ref or die $!;
	binmode($fh);
	my $content = <$fh>;
	$ref = \$content;
	return $ref unless length($content);
    }

    "PAR::Filter::$_"->new->apply( $ref, $filename, $name ) foreach @$self;

    return $ref;
}

1;

#line 106
FILE   #5552145b/PAR/Filter/PatchContent.pm  �#line 1 "/usr/share/perl5/PAR/Filter/PatchContent.pm"
package PAR::Filter::PatchContent;
use 5.006;
use strict;
use warnings;
use base 'PAR::Filter';

#line 22

sub PATCH_CONTENT () { +{
    map { ref($_) ? $_ : lc($_) }
    'AutoLoader.pm' => [
        '$is_dosish = ' =>
        '$is_dosish = $^O eq \'cygwin\' || ',
    ],
    'Pod/Usage.pm' => [
        ' = $0' =>
        ' = $ENV{PAR_0} || $0',
    ],
    # Some versions of Spreadsheet::ParseExcel have a weird non-POD construct =cmmt
    # that is used to comment out a block of code. perl treats it as POD and strips it.
    # Since it's not POD, POD parsers ignore it.
    # PAR::Filter::PodStrip only strips valid POD. Hence we remove it here.
    'Spreadsheet/ParseExcel.pm' => [
        qr/^=cmmt\s+.*?^=cut\s*/sm =>
        '',
    ],
    'SQL/Parser.pm'      => [
        'my @dialects;' =>
        'require PAR;
         my @dialects = ();
         foreach my $member ( $PAR::LastAccessedPAR->members ) {
             next unless $member->fileName =~ m!\bSQL/Dialects/([^/]+)\.pm$!;
             push @dialects, $1;
         }
        ',
    ],
    'Tk.pm'             => [
        'foreach $dir (@INC)' => 
        'require PAR;
         if (my $member = PAR::unpar($0, $file, 1)) {
            $file =~ s![/\\\\]!_!g;
            return PAR::Heavy::_dl_extract($member,$file,$file);
         }
         if (my $member = PAR::unpar($0, my $name = $_[1], 1)) {
            $name =~ s![/\\\\]!_!g;
            return PAR::Heavy::_dl_extract($member,$name,$name);
         }
         foreach $dir (@INC)', 
    ],
    'Tk/Widget.pm'          => [
        'if (defined($name=$INC{"$pkg.pm"}))' =>
        'if (defined($name=$INC{"$pkg.pm"}) and !ref($name) and $name !~ m!^/loader/!)',
    ],
    'Win32/API/Type.pm'     => [
        'INIT ' => '',
    ],
    'Win32/SystemInfo.pm'   => [
        '$dll .= "cpuspd.dll";' =>
        'require PAR;
         $dll = "lib/Win32/cpuspd.dll";
         if (my $member = PAR::unpar($0, $dll, 1)) {
             $dll = PAR::Heavy::_dl_extract($member,"cpuspd.dll","cpuspd.dll");
             $dll =~ s!\\\\!/!g;
         } else { die $! }',
    ],
    'XSLoader.pm'     => [
        'goto retry unless $module and defined &dl_load_file;' =>
            'goto retry;',                              # XSLoader <= 0.10
        'goto \&XSLoader::bootstrap_inherit unless $module and defined &dl_load_file;' =>
            'goto \&XSLoader::bootstrap_inherit;',      # XSLoader >= 0.14
    ],
    'diagnostics.pm'        => [
        'CONFIG: ' => 'CONFIG: if (0) ',
        'if (eof(POD_DIAG)) ' => 'if (0 and eof(POD_DIAG)) ',
        'close POD_DIAG' => '# close POD_DIAG',
        'while (<POD_DIAG>) ' =>
        'require PAR; use Config;
        my @files = (
            "lib/pod/perldiag.pod",
            "lib/Pod/perldiag.pod",
            "lib/pod/perldiag-$Config{version}.pod",
            "lib/Pod/perldiag-$Config{version}.pod",
            "lib/pods/perldiag.pod",
            "lib/pods/perldiag-$Config{version}.pod",
        );
        my $contents;
        foreach my $file (@files) {
            $contents = PAR::read_file($file);
            last if defined $contents;
        }
        for(map "$_\\n\\n", split/(?:\\r?\\n){2,}/, $contents) ',
    ],
    'utf8_heavy.pl'	    => [
        '$list ||= eval { $caller->$type(); }'
        => '$list = eval { $caller->$type(); }',
    '|| croak("Can\'t find $encoding character property definition via $caller->$type or $file.pl")'
        => '|| croak("Can\'t find $encoding character property definition via $caller->$type or $file.pl") unless $list;'
    ],
} };

sub apply {
    my ($class, $ref, $filename, $name) = @_;
    { use bytes; $$ref =~ s/^\xEF\xBB\xBF//; } # remove utf8 BOM

    my @rule = @{PATCH_CONTENT->{lc($name)}||[]} or return $$ref;
    while (my ($from, $to) = splice(@rule, 0, 2)) {
        if (ref($from) eq 'Regexp') {
            $$ref =~ s/$from/$to/g;
        }
        else {
            $$ref =~ s/\Q$from\E/$to/g;
        }
    }
    return $$ref;
}

1;

#line 157
FILE   53581051/PAR/Filter/PodStrip.pm  �#line 1 "/usr/share/perl5/PAR/Filter/PodStrip.pm"
package PAR::Filter::PodStrip;
use 5.006;
use strict;
use warnings;
use base 'PAR::Filter';

#line 22

sub apply {
    my ($class, $ref, $filename, $name) = @_;

    no warnings 'uninitialized';

    my $data = '';
    $data = $1 if $$ref =~ s/((?:^__DATA__\r?\n).*)//ms;

    my $line = 1;
    if ($$ref =~ /^=(?:head\d|pod|begin|item|over|for|back|end|cut)\b/) {
        $$ref = "\n$$ref";
        $line--;
    }
    $$ref =~ s{(
	(.*?\n)
	(?:=(?:head\d|pod|begin|item|over|for|back|end)\b
    .*?\n)
	(?:=cut[\t ]*[\r\n]*?|\Z)
	(\r?\n)?
    )}{
	my ($pre, $post) = ($2, $3);
        "$pre#line " . (
	    $line += ( () = ( $1 =~ /\n/g ) )
	) . $post;
    }gsex;

    $$ref =~ s{^=encoding\s+\S+\s*$}{\n}mg;

    $$ref = '#line 1 "' . ($filename) . "\"\n" . $$ref
        if length $filename;
    $$ref =~ s/^#line 1 (.*\n)(#!.*\n)/$2#line 2 $1/g;
    $$ref .= $data;
}

1;

#line 85
FILE   1d07138f/PAR/Heavy.pm  #line 1 "/usr/share/perl5/PAR/Heavy.pm"
package PAR::Heavy;
$PAR::Heavy::VERSION = '0.12';

#line 17

########################################################################
# Dynamic inclusion of XS modules

my ($bootstrap, $dl_findfile);  # Caches for code references
my ($cache_key);                # The current file to find
my $is_insensitive_fs = (
    -s $0
        and (-s lc($0) || -1) == (-s uc($0) || -1)
        and (-s lc($0) || -1) == -s $0
);

# Adds pre-hooks to Dynaloader's key methods
sub _init_dynaloader {
    return if $bootstrap;
    return unless eval { require DynaLoader; DynaLoader::dl_findfile(); 1 };

    $bootstrap   = \&DynaLoader::bootstrap;
    $dl_findfile = \&DynaLoader::dl_findfile;

    local $^W;
    *{'DynaLoader::dl_expandspec'}  = sub { return };
    *{'DynaLoader::bootstrap'}      = \&_bootstrap;
    *{'DynaLoader::dl_findfile'}    = \&_dl_findfile;
}

# Return the cached location of .dll inside PAR first, if possible.
sub _dl_findfile {
    return $FullCache{$cache_key} if exists $FullCache{$cache_key};
    if ($is_insensitive_fs) {
        # We have a case-insensitive filesystem...
        my ($key) = grep { lc($_) eq lc($cache_key) } keys %FullCache;
        return $FullCache{$key} if defined $key;
    }
    return $dl_findfile->(@_);
}

# Find and extract .dll from PAR files for a given dynamic module.
sub _bootstrap {
    my (@args) = @_;
    my ($module) = $args[0] or return;

    my @modparts = split(/::/, $module);
    my $modfname = $modparts[-1];

    $modfname = &DynaLoader::mod2fname(\@modparts)
        if defined &DynaLoader::mod2fname;

    if (($^O eq 'NetWare') && (length($modfname) > 8)) {
        $modfname = substr($modfname, 0, 8);
    }

    my $modpname = join((($^O eq 'MacOS') ? ':' : '/'), @modparts);
    my $file = $cache_key = "auto/$modpname/$modfname.$DynaLoader::dl_dlext";

    if ($FullCache{$file}) {
        # TODO: understand
        local $DynaLoader::do_expand = 1;
        return $bootstrap->(@args);
    }

    my $member;
    # First, try to find things in the peferentially loaded PARs:
    $member = PAR::_find_par_internals([@PAR::PAR_INC], undef, $file, 1)
      if defined &PAR::_find_par_internals;

    # If that failed to find the dll, let DynaLoader (try or) throw an error
    unless ($member) { 
        my $filename = eval { $bootstrap->(@args) };
        return $filename if not $@ and defined $filename;

        # Now try the fallback pars
        $member = PAR::_find_par_internals([@PAR::PAR_INC_LAST], undef, $file, 1)
          if defined &PAR::_find_par_internals;

        # If that fails, let dynaloader have another go JUST to throw an error
        # While this may seem wasteful, nothing really matters once we fail to
        # load shared libraries!
        unless ($member) { 
            return $bootstrap->(@args);
        }
    }

    $FullCache{$file} = _dl_extract($member, $file);

    # Now extract all associated shared objs in the same auto/ dir
    # XXX: shouldn't this also set $FullCache{...} for those files?
    my $first = $member->fileName;
    my $path_pattern = $first;
    $path_pattern =~ s{[^/]*$}{};
    if ($PAR::LastAccessedPAR) {
        foreach my $member ( $PAR::LastAccessedPAR->members ) {
            next if $member->isDirectory;

            my $name = $member->fileName;
            next if $name eq $first;
            next unless $name =~ m{^/?\Q$path_pattern\E\/[^/]*\.\Q$DynaLoader::dl_dlext\E[^/]*$};
            $name =~ s{.*/}{};
            _dl_extract($member, $file, $name);
        }
    }

    local $DynaLoader::do_expand = 1;
    return $bootstrap->(@args);
}

sub _dl_extract {
    my ($member, $file, $name) = @_;

    require File::Spec;
    require File::Temp;

    my ($fh, $filename);

    # fix borked tempdir from earlier versions
    if ($ENV{PAR_TEMP} and -e $ENV{PAR_TEMP} and !-d $ENV{PAR_TEMP}) {
        unlink($ENV{PAR_TEMP});
        mkdir($ENV{PAR_TEMP}, 0755);
    }

    if ($ENV{PAR_CLEAN} and !$name) {
        ($fh, $filename) = File::Temp::tempfile(
            DIR         => ($ENV{PAR_TEMP} || File::Spec->tmpdir),
            SUFFIX      => ".$DynaLoader::dl_dlext",
            UNLINK      => ($^O ne 'MSWin32' and $^O !~ /hpux/),
        );
        ($filename) = $filename =~ /^([\x20-\xff]+)$/;
    }
    else {
        $filename = File::Spec->catfile(
            ($ENV{PAR_TEMP} || File::Spec->tmpdir),
            ($name || ($member->crc32String . ".$DynaLoader::dl_dlext"))
        );
        ($filename) = $filename =~ /^([\x20-\xff]+)$/;

        open $fh, '>', $filename or die $!
            unless -r $filename and -e _
                and -s _ == $member->uncompressedSize;
    }

    if ($fh) {
        binmode($fh);
        $member->extractToFileHandle($fh);
        close $fh;
        chmod 0755, $filename;
    }

    return $filename;
}

1;

#line 197
FILE   ad0c6a94/PAR/SetupProgname.pm  �#line 1 "/usr/share/perl5/PAR/SetupProgname.pm"
package PAR::SetupProgname;
$PAR::SetupProgname::VERSION = '1.002';

use 5.006;
use strict;
use warnings;
use Config ();

#line 26

# for PAR internal use only!
our $Progname = $ENV{PAR_PROGNAME} || $0;

# same code lives in PAR::Packer's par.pl!
sub set_progname {
    require File::Spec;

    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $Progname = $1;
    }
    $Progname = $0 if not defined $Progname;

    if (( () = File::Spec->splitdir($Progname) ) > 1 or !$ENV{PAR_PROGNAME}) {
        if (open my $fh, $Progname) {
            return if -s $fh;
        }
        if (-s "$Progname$Config::Config{_exe}") {
            $Progname .= $Config::Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config::Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        my $name = File::Spec->catfile($dir, "$Progname$Config::Config{_exe}");
        if (-s $name) { $Progname = $name; last }
        $name = File::Spec->catfile($dir, "$Progname");
        if (-s $name) { $Progname = $name; last }
    }
}


1;

__END__

#line 94

FILE   cb613bc9/PAR/SetupTemp.pm  
package PAR::SetupTemp;
$PAR::SetupTemp::VERSION = '1.002';

use 5.006;
use strict;
use warnings;

use Fcntl ':mode';

use PAR::SetupProgname;

#line 31

# for PAR internal use only!
our $PARTemp;

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::Packer's par.pl as _set_par_temp!
sub set_par_temp_env {
    PAR::SetupProgname::set_progname()
      unless defined $PAR::SetupProgname::Progname;

    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $PARTemp = $1;
        return;
    }

    my $stmpdir = _get_par_user_tempdir();
    die "unable to create cache directory" unless $stmpdir;

    require File::Spec;
      if (!$ENV{PAR_CLEAN} and my $mtime = (stat($PAR::SetupProgname::Progname))[9]) {
          my $ctx = _get_digester();

          # Workaround for bug in Digest::SHA 5.38 and 5.39
          my $sha_version = eval { $Digest::SHA::VERSION } || 0;
          if ($sha_version eq '5.38' or $sha_version eq '5.39') {
              $ctx->addfile($PAR::SetupProgname::Progname, "b") if ($ctx);
          }
          else {
              if ($ctx and open(my $fh, "<$PAR::SetupProgname::Progname")) {
                  binmode($fh);
                  $ctx->addfile($fh);
                  close($fh);
              }
          }

          $stmpdir = File::Spec->catdir(
              $stmpdir,
              "cache-" . ( $ctx ? $ctx->hexdigest : $mtime )
          );
      }
      else {
          $ENV{PAR_CLEAN} = 1;
          $stmpdir = File::Spec->catdir($stmpdir, "temp-$$");
      }

      $ENV{PAR_TEMP} = $stmpdir;
    mkdir $stmpdir, 0700;

    $PARTemp = $1 if defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}

# Find any digester
# Used in PAR::Repository::Client!
sub _get_digester {
  my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
         || eval { require Digest::SHA1; Digest::SHA1->new }
         || eval { require Digest::MD5; Digest::MD5->new };
  return $ctx;
}

# find the per-user temporary directory (eg /tmp/par-$USER)
# Used in PAR::Repository::Client!
sub _get_par_user_tempdir {
  my $username = _find_username();
  my $temp_path;
  foreach my $path (
    (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
      qw( C:\\TEMP /tmp . )
  ) {
    next unless defined $path and -d $path and -w $path;
    $temp_path = File::Spec->catdir($path, "par-$username");
    ($temp_path) = $temp_path =~ /^(.*)$/s;
    unless (mkdir($temp_path, 0700) || $!{EEXIST}) {
      warn "creation of private subdirectory $temp_path failed (errno=$!)"; 
      return;
    }

    unless ($^O eq 'MSWin32') {
        my @st;
        unless (@st = lstat($temp_path)) {
          warn "stat of private subdirectory $temp_path failed (errno=$!)";
          return;
        }
        if (!S_ISDIR($st[2])
            || $st[4] != $<
            || ($st[2] & 0777) != 0700 ) {
          warn "private subdirectory $temp_path is unsafe (please remove it and retry your operation)";
          return;
        }
    }

    last;
  }
  return $temp_path;
}

# tries hard to find out the name of the current user
sub _find_username {
  my $username;
  my $pwuid;
  # does not work everywhere:
  eval {($pwuid) = getpwuid($>) if defined $>;};

  if ( defined(&Win32::LoginName) ) {
    $username = &Win32::LoginName;
  }
  elsif (defined $pwuid) {
    $username = $pwuid;
  }
  else {
    $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
  }
  $username =~ s/\W/_/g;

  return $username;
}

1;

__END__

#line 183

PK     X{A               lib/PK     X{A               script/PK    X{A�����  Yj     MANIFEST���s�ƒ��_��W/N6#�dǉ�*��a�@I���U
-����'�MZZK�vS׶7ջO�	e7�J���JX�a����E��T�	�{���糭$T��y��Rz:�Y�~�
*�v+�Bxj�tGp�� ��K�BO���5�;���L�I��l[p��4^��Lgn����E�+h����[��A�``ۏ��j�b��,,p��/.z����w1ZK��ݧ�:3q�㇩~�d�;s"�&:�b�z���4x����/-����J��z����lft*���Me��P���y7����V���h��u�"7�Vprub�]�i�����Fz�3j
Ү�x���׵�Y���L7ܳ@>��ׂ����7�'�<�\�(F�kӲ4��:]g�c�Ү{�`0Xɺn��J�p�:n�ӉZl*
����:�ZGuZ�� �q���֫:-���8�kK�����S��E�@�H,��$�n[b`�*�J��! m�цC P.:WmH����. }��AkϧT�
�;(aW�0d�[��i�U�Dr� ��Z]�?'a��B(��!�'�N��sJN�x����ۉ�6��?��
6�f��nV�j�-Srl��c�TӤ�8{Q�-|�E�-��z�r��{s�5ϭ63�s_r�h���47̭ۛ�r���@s���X����%��/9�O��ǽ`K?RŜ��U6��~�2ؓ�\b��fў/�tq�o'�
���v�T��W���м�n��E�-p�V�_r�a�K�
7�3��yh�~nLš��b5w��
;� N��z���q����*�Y�}�?D���x�d�0�se�y܄=N�?B�U}�a�*y=��:�<=��	R3���2l�\枼�����P�iXo.��ͽ���^�5*�ܦo�p��p?*�k5c�Ke2\u.)�4���'>�aމΟ��q+�` +�^����:8o��.���.�d	i�8
SM��Ѻ�N�;�*��?�*K��u�MGo҉�c~�a��8�q�5�⯿�q�ݔ�#��v�l����yj&*�ժ�T6Q8��KV�{������P���=W��!Γ���0���f2Տ��y�
"�B���`�a���¢�F=��;�68�68�68�68�6���� �����������0�'��
"�/(�7�S�wT�*ը�4�`�[0�qj������%$0�}
YÀcId���	Hۊ#:"��%gű#/���\Xy�Q*�t�%"=ym��8Nc�lSYy�����P��cG&�d�9J8�A��j+ٕ�\<&E�s ���r#p+ʟ3��5AST)��p��G��Φ �M
"��������!�XL�H��$'T,�-�b�g 6?���8z���v��@tLP��Ori�Y�+�w�Rr&9�^�B�T$��*�8�f ��[��6ן��Q�� 9��ѽ2�����LP�%�=��^��G��S
J����E�-�db�-pV���F5P�u�� ��T;��Dֱ� |A�9p� XG�g��B'��uP
������D�1��B\',��
�<(X��7|�91�_��-2�6��u1�QW���(7X\��F�����Y���"q�8�m�t_,�/b�J�H�Db��1�'.$o�8$�l�,��;}���'�!�t�@C�,ġq=���F`�;�@�j�⤂�<�&p��8K�Ã4���D=yj�e>�(���/bu#�	��2ŏ��T�Ⱥ��2yy��q}���4��	�3a�RAD�^3R ��Z��1B�O�ߔh����@�@��5)��I!?&zY☔���^�1��$��,�
�֐:T��ᷰ�C���&�fA �B &�(1��
�7��{w����z�M=w�N����A��A��A���@��A#�!+��Ȼ��!u2T��Md���2dfy�2��}� �V�CX�HCވ.@
8��X�R -�;���H��������I5��@TM,u)�v�)y0�܁�P���~�E0}tx��N��k��*&����>���í�>�����)�5��>�U��_\��J&�
[��I.۶�UV)��5)ns�H�P�Db�d���b����%b+(P&�iFZ����[��^yy��Q>�)�#��j*+�Hv~��7R�#'�,�h!�pd���5!�f �!!pE!���X����:��M��{W�Q�:���*	J !T������}�y�+" �_�1��s�J ��}�p!wp2�Eɐ���L�<T�X������"��#�wK0r��t3
$��8���k|��f�f���o�4�
��q�yD��"�K>����g��'����]�7��H+�X(>՘+~�sA�7^�9FI�M��v{���]�bY`�φG��6���RL,�ln��60��LF0�k�0�4%��i�4)��f0�
��I�N��û�A�i��H�`g�-%�WJ*vΦ�搰K��4O�;��3rX�N�d L��2s��ɰ���=@�6.%�u��A���J$�W6���!`|@����� CD�U*�ճ�Y3�avص�%�.9d�ͼ+�*x�:��������(di'*�0���^x�҃�����a��=7x�d���
�9����QE~1Ձ=_VX�~��ʋ�3�%٢�z���۰���)��4�Pm=T�S�z.�f����
>!m뜜��Y<��}:J/��s�%4-͍\�8~��c]�����������W�nUD���x]�3G�@*�(�*J�u��*}5��>0�1����ʴ�n!�\C��6���\��l|�詫�Sf�
�2M�4���hA��V���mX7Rn�����w�`؂���J�IR:r�i�G��ng���;Sl`=J��:��n����OW���:-�Uڎ�vԞ
�0]��W�R�~L����"x�#x�A�w	�{��b��)1R���EY�ѱ�}�˻X����j����fX��Vi��
1b�c!Ǟ�J��O�y�-�^E_=��t���м��~b�~��^|�����T��/"/���n�� �����ЮAqk�����iUK�<����G"y�@(�m��3�jo�
� ��FO��U��F��h�c�(᷶c�;��%گ`Y�
��_\�}�s+�`�y-ߒ�	�8N�WQ��N�U�}Ӓ��5�Bq���$�PPb�P�FV�$�rF�ˡ���lٶ���=����P�ߦM5�v�B��d���5��,#�Y=])�{�j�]\RZ�ȌC��2͍ˢ%殬d���}�9[�Yc.J�X�1�KF�б���䩷�i�o�5u��$���R�����\�;Oʚ�L̲���5���T
������ t6Z���\_�U�+��M�
�hx}u�8/�rjzX�U�v<,��������#�u�M�T�m�(�\,u�Ju������Sz��mꫜ�/�7�����% ]i6l!W� ��\���; ��K�8��v������ �5a*X�{���߮%�v��5�����$����� /�P������F{����F2S�= �A��& � q��^@: ��Z�P�#F]���$#S�8ʌ��b�MşͰ.���X��h��HL8�`�L�)��}<0����6R��������ؾ<��a��gbZ��$�d��\X-��J������0�V��z�Sh���|j�t�F�
C��8v��/��ۛn{и�~o���)Ԉ�{V���b��ڗ��8Z�Zá�wC���2���;����T)�i�A��հ�Q�o����4���g[ۯ��'L��i�<x��f�@vê8c&�'��ǩcMQ��c��}�:b
@�ãu	���
o_f�[�PZ�G[hig<�?^�oi�z�KV���Gu�ĺ��.��(s}?ح�M�}�9���o)$���{�4??�NT,�&�v��,VX��W�lɈg��w�A�ڟ���ς�$�~eb���<���kr�z �^�x#{@��a����t������ߛ��sx����]$05^Sik��]!A-{Jj])"�&̩����Z��(V�вڋ����jX��V�HWQj�]��D��&�ЀǨ�
�4�Rt���{�\��H�5EX����6<H��"�V��*�
��Oӣ.q��ݐ�
z�[9z�#zÓ5�*u=!�lZ|�����rz��<߽��g�~eO��(e����R�M��}h*q�����_��p��Ѐ�֎UEE
S�Q��� ���,'��(
�aEA�ga�W�<��1��Y��gQN�$�J��
Pĳ`>Di0;���8
fQ:΂0��t߳h4l�W���N�,Ʉ�H��� ��?'W��p�OF��E�fq�Ѕ ʲh2����*�$����� ����x�A{Ӱ�1<��I]�?Ϣ�e�N�����zf0P��&Ɍ�fa*��σ�<�����俢�,H����<���LN��v����6w�/��ۯ�_/7�n�nJ�_�_�/�[�������_��������ͷ����WTe����������.���~����s����Eo����7=x��ry��sp�{����X�7wz�x�y������ۭ�-����w{o��m�Ц���o�{���(���?_lP���a\���jzw���������K�7tu���>#�����g����ao{�W��#?��������J^o���d��wo����7���K�x�u���+���=����|kk�~y�v��.�
c9��y�El}��ݝ��һ�o��n�0���Λ�[��׻o_q���v^m�j4�Z�z<	�o//��4x��ZP3S��v��V-������_m��8m۰�j�^5��v��2��~����
���_��hp�n����Rc��[e^���ES��۶&#��r�[=���.������������*V���	6��J{��
X<m��~'�֩n�?�}������@�&p$3@�~����7�;�5튥`+��(��U0K��Q4��H�4Ig�	Т�hv=��,25J��T,'V��`>
�9/Oqhp%`e�?�����5A�׵d7��v��%�_��S��Y:��l��zU�=�
	�H��@�`�^����e���:�����x
�UB�$�b���]�Y��ò����l�D
ބ)pH��9t�/��k��d �am��Vz;m�"�1�A��֨���
-�B~�.��ӑM"ۢ�d$�����0-$��#�F�-XR�Z�k���{���W�,\[{5O�f�`��Q�"0s1�as�e��s2�4�d\3*;�A���������o��[3�Š��� ��$�DQ@���M,��Ԩ*�CѠ���r&���V�(9��9t��$G�4�Di8������ڼMF�p�a��Ȳ�_�W�-����r
;�2
�5(�?����v���/�W`K�%�l��8·7������H6�f-�x�6�����gIK�=i����
nW�\��V���uM#��'8�#Ƨ�o��d^g0��6�Z��s� ��6�_߽m����H��k�0�\�΢��<kI±�Ö����2c�P�-T��͸ ͉�PT?��)���M�z�x,מ17*L
�r[5[	�.㹮^�������Λދ�Ã� �T�W.WV�o��A'}	x
�}��wX���h\v&r�{%��G�0X�1��-�k��F�4��..��txDp-�Xq8ڟ�126|1��ds����ݥ�f�
+k�b�Iܙ��-���%@y:/:��e
d8���
� p�2:��a���QK�CC����7�EJ��x2O�����3���!�BԊ���u�"i��C`L�8��%iZ>FW"���gW��ќ,\P1�\iC`��4���Ȕ��IǨ��h������% U�52����)�zw�5��.&=�a�&f0j�ԓ"re��D�7�E�HF "�]�ㇾg�J��r�z���K%�־���D�Dm�&�j*� %�My�}n���	�
w=Mm`C7Fp�F,�0��I�*������1xq�B�����ط6��ۍ��v��$��u������5�?y�$�ɇ�Ԕp���-�j
/��I�C}'S2~��ӛ!�[�!��;:�}�{��vɈ�l۠^!ۖ��y(�X[N��n, LI����9T�;�R�)�}��X��q�ja�L�����8e�]jsN
�������N;�
��W~v�����?��|�.HPW~t��<	�b�W~pz��PuA���w��r�d#x��f�)����k�;lc#x��OQ7 ��?F��ӓ�X��}���� �����ϟ�F��@Q�O���-��)�o���ц�~?8-4�a�;~_J�1��&�*b�;hX\,t�
t-���Aگ��o�V��TQ od�@�m	ڬ��A8���W���ZO_o���v�˰��z�M�1���k�d7��n5����2����ۯ�z[� �D���ob|�O�X��
#88��?�zO[���CJŭ��H[x#rY;�S\���j|5�o�nn��Q��qg�����3)�ɒ����B�UK��Րbk2�T���ە��J�J�|�"��\�,5i�ӻ������l���S
UZO�V�M�鹚�7L)I@j�������
��r�QW�K&HD����N�.XagvYN���d��Qw�E<N�9�P��x�O��fH'�i<��J�\_�=5�A4����Uw���k7h>M���_��x������`X7P�LZ�����A�j55՚j7Έ��m����������GZ}�#-�?�qwH&X��[!�.O�����J�@��w�I��ή����
v@
Er|/;�l����6�E�:�Gkkǧ^q�=Wq���Q�����4�~�;VϏ�����
C�m1u�HϹ�.��@j�T��U?����8�s=�>�Sc0��l�8L?2��s���d������b�LP�:ץ6�=��՚�{��-���Y*�m0��F%���?�#�-Śaڹ
�'�������6����aA{���`Q�$B����6��v^k��|Pkך MLATBS(�qE���[�Ȣ��&��I�Ҡ�/�$XW��*�񲩣�-���"*i1�l�{�T,A[�.��O*ˇW�"(z��
|B-\�|�YkWnl���o��J/R�����r�����G8vz�aD4*��yC3t �$Y��gn�����Ͳlҳ���vѺ9�S�5��=R�+U�~c��w�!����&�D�cv��7B�|�U�:k�� ��m�ղ��&��S23��F��Ԓ�uE!��.P#l6�0��l2���C�[O_~h � ���_���To�Ʀ7�p����_�t}5*O6_�����kͬ�fћ�^AV�$��6#h-�6��A�_��|s L�h�7�e^|�n��/P#��.�����U��F����達v����V6E,�8��k�εcl�$T	�#2�Ɓ@cWظKt�M`jd �!<v�j���8��ӹ~#D�ǈ��ň���:�u�foX�o�X��FI�	G��@�H��4�p���X����u��z-�ϛuV��F� �O3�8�1��}��NBig_�Sw�
�A�Q	ր���A�A{N�@]FP`E�/�"�������<$͸\�"�g��
�:W������������.�bJN�a��X��nERV���G�>8hi�Ҡ��V�G�ٸ�<fM�Ӡe*�*ޕB��}U&55����}=/��y����F���Z�ee�c�����U�[�
�j��Ġ� �롷���'S�J�:���Ή��8C���iD�P��������y��[I^~G.�d=��ףcﳘkV����.��wӲȣ�k8>�q@az������̺ ��̲9�̉6�ԦۅX��da;q��7��H�)��E&D�b#{�,`9�֠�Y��N�zR��֜�F����GkXo?jt�5������K��.9[��޴����Jj�Ԛ$D�U�T4oֆt�)���B�2��rH�]!����(��K ��j�T[G�![�-E�tM��O�ЩH��Pq�,��'y�Z�):��m���R���g>`G���:�n��v�(�O�݋�֠�ۊ�my��Fg�pg��-��؜������QL����L)��|4�H!��4N�$��IT'�\�u��I©e��j<��:Ѿ��@�)������Q��&�^8��,�d��{��-�l���Z�
`���p)��J\�S
�)�ak�U(�dP�@}q� q��W��n�s�T�lJg�ܤ��-F˲�yQ?�k�����J��j{�׫���������c�8r�E ��d] ����dk��k�K����y>qޢ�������o���q��
(�u�k�l�S�c�5@�&����5�:�a
W�Y�6U?�[���Zy����|�4���s�uC��B��-Gʇ�` X��rzJt��͏Fj�+����hh���To*��L�G.�G/��+W*���2ST[�|��+Z9'��Ԕ�HUjz6���U�(%r�����"��*�&jP�{�'�ŕ�"������v[C�NCiq�F	����G��o��������juEjC�r~�sj?ǲ\��"�ZP�7����5��p����tW��T�M *�*��+ᛶ��/�0@~M+��ݽi�-�gR���]W��d_�����*77%��툻c)�z��G�F�d��L#�!9"B��r3�`3�����߷oۇz���A-f:/L�3i$W������E3������w��(Ӱ����#�����.�K��f�j[���ւC�Ҫnwq�o��ūu&��N%m?���	&�;+@Ã5&!Oy�͉*S��jg�knH�_��R✊�� L{v}����<�E
�Xb�X�uB�8��c[If2�x�|�G����k����u��i��l�52I�w`�΋�~��U��'0]����=�9����Pü��:�\T�`A��U�z
�VƎi<�w�FDȘ�Z�$.D��o���
)X@��Sz�҉ǯ�zn����?'i�ڡ�:݀Mt/���F�dE+hv?���,�QҎ
���<��,��ߊ�
H�qL,}�y�.֓р�~0��׋�$�g �0ds�r��	$P|L&�hkt�T��)Z�4�n������U�m�R���.�w�&�:`r�F̡*��.��- ;z�4��A�i��b� 1F1;�x�6,
_+���iOeu5�7w�2^��("����#s���nUe�;~�}S�!c��hű0xB����t5�{;������C���ؠ�Dz�烍�;����VW��o�����N�J���b�5�3�I�(R!4ae�?
��zP��B���h4S~,Ы
[j�`�)���^LC�p?���F�fQ�K+�'��n�(�%yZ:8;�-�h���j�Þ޺y�ܕ21����8y\Ϟ��m�G�m�Rx����b� Y�{��#��(V/��Sd
�/f�O�?���8������37���zj?;�O����4K�8i��fb���_25NfX�G��k�i�W!Hr4�z�k�m�R��j���-T�����݋�kk�G��W�a��!��� B�#Y>�n�ͺ�A�;+?�bº�l��1�R:M�%�ŝ�=��ja�1�0���W���G�gJV"wx���{H���ۢ��l�Y��²�}���̙vl9;��>]p`���cE�m��m���؉U�6ۘ�,�'i�'
��c���.h�j���y�N���۟S-w���Z��l=��|�v��P��Ѭ�ܰ����8k�E��S��3�7�"�0�Rғ����!yH7�`|U��G����
T�Gd��XI� H�&�|�Gt
-M3G�钁Rl�y��7�,-�.c7L��X;̨�:�-M�v�z���#U�������Ą֩W+
�i��*
�*��O#l�aV��-i	�2���Ż�}�[?������6���y�S�պ�M�-�/z�'�V�����9�������At�@� J����շ�tK�i�9�
���@�K���)��,'(|�A [�M��xok0���و�R���6�}���RT���(�d��i���G��X����Iy12���<e^ç ZX	��Q�.�;%�	�<�g
@�@Pmm�h e�Jo*� =���R��$�4u00�ْ�'DQ� }���'�"&�S+[)�CL��%�lEy�P]�A�t���#5�����u�E�0I�7��
������}FrG�kQ�����r]��<~�*�oЦ����������P~����߶w^V�<����X���F��^��8�	�@q�^��2iv
J(��	�V�Y�N�Vp��qe,kQ�T(�i0X'�a`v�䕷J�Sɒ�Z�_���V���N7r�C�#�[�+����6��k'��{���I*Y�a�z���M�ʺQ�Q�8v��e�g�b�	��z�ε�xHx�i��uWo����@X����{'W��֏�i:!ʰ
��	���:j$ M�NR
�6�>t�c��2w��$��Lo���a���������杔��f�~%1�$�ܻ�ª��ɁG�>���K�I4���WEVUv<����2aՈn)Z�R����ffٲm�9�\o�uz�/P�
����������偁 J;��[��Ce1Y�4kq��$�չ����<<Ɠ,J�m�$J:$�fZ�)�ο�}�/�Q�î[}!��&��,���M�53R���0^�C.�Y��O|�āa�v��Tm-vh�|��bP9�\�ơFK�-
���"@��$�������
�3-WA����ƫ�`����!a����V��mHD]5�zÿ�"��e�.}AZE��0-<`�5X,]^���G�l��sX8�4�}ȵu<���F��x�ŵʮ8�Ѽ`a-q��3o �9�9ÔlЁ;Ű[���DŰ\�RğB`���[�Z>��Qq��ɠ��Qa�6�稤� \�稸� ]����E�d\x�Y`V bW}��Ӵ�i*v�.�
 �"@h:�����SqE��݃��ۿS6�`�߁����
btە���{�.��o�U0��=�V+��D��iW5�fnhi�A|��wS��G��qa�f�o��/D�b�	��Y��j�� �1��k4���0@(�5�1b��W�V�R�.d5̩�Ь����yx�R��~��b3zf<�jr'����O�z��s� �ﻻ�An8��;E�(g���lE�~E�
e)��#��H5��\;I��.� �hF��B�K�<�$r��@2UO��N���`��w�������Ign�
�a�mm���]�+�K�Çe����g�G���v��S;�m�R0F�oW\�|��xq(
S�}F|u�3D��T��(,���{|k��S%��F��hE-�5���Rf��!�
q�E)��Ş�m�p�n�'����
�n��r�	i6�B�� ����*DK�ȭ�	�4���M���GݥldK�,,q��\�S��\
b�G���=���N_�5��X���%�G%�v%�]�80\��_����_����Y�6E%��ģ�X��'�|�U�'�� ,pf1qI=���$�ܞD�Bc7�%���Jⶣ�}eR��<�*w��l�v��#�Է� ���(!�Go�q�8��C���J.jg��2�E<)�'��L�n�!U��*���O`�[�h�L��ia���"����t��P�C`F�
e�Չ�$C�]k�В3:�\rO��񜞝\m\���W�X=������D�����'Z��P�im���%f�.�-�$fF��������a�6�y���S>=M�Q�v��F�.k��?����K� Γ�w7Ha�v�>�3���h��ѡb�8�K5��]T�6�4>'OûK�R��n"Cf��^X�u3�3 SMI�jǋ�j�TI�ƚ(�J2m�㼰y���f2��I�n�u�i��4�=Ss�u���n:��^:�����J���
�@t�ϓ�n�׊���W-�
yH�d�ba%�O}�a�7˹�٣lv{PՒ8#@X=M�cR������A����|Q�i��@F��<�<�Q�j8nw���Z�7��j����Q�,;\��3��{.�����I���Q^J���!b�[7��D`П��>h�85c]���߳�n��2��M:K@��7�U�f%��ü!����d���Fq?*��{Np��׸������j���LP����ϝ���u*1�W��d�������M�%t�����./J)�ʯ��-��>6�sL^���^l�oi�n�OY���&����t��Q��hm���)�t��1�63��2�����{Z=��X�(,���}Թ���F��9ίd.��-d񃣛l*�d)���߃�0�5y�I����O�D��{�!z.������c
�F���Q4WD�Ĝd��ð�[�s�˧)=�&��]_W7�����Q�ҬW����>b���>�T�o��JEݺ�1�z�ivsiwJs� ��	W��`�xY�9Q07��1	0t��+:����Jgx�����2!���Q�;z�y|]ḧ_�A>1������Z��v�-/�%���s��N�i���<���S쩓۳.��$���n�958�5�#�d��>��n���r!����U�R�8�΃��@H�D	8!N���Qb*�!l�"D=X��2�G��N�k��72�ؽ!��k[[�Խ�����V�=|C�$�7��v��?��En�����
�BV�|%��D��Q�y�s�7H,��[�]M�$p(x �˕�z�6G��4\�� ���'�h�S��ԭ��Y�×�Oa��0��s�r�Ỵ�̮��s��Rbo����~~Xf�X�z�﻿9�uޮ��EÂesg��U���'Ü�}��_��ajٍk�T��t:ǐTQ0C�<��05ǻ�2ː1Zݢ�|���T�gO�=�N��O��S�.:k�D�+`w<�Riԣ�#���pv�Y(R�ٽ��Vu�'\o@�N�%d7�^��{vt�c։�\�f�|���$`�	 9H�ŁxI��0�t�d'w��˙����E��-�#8�?`a��u�c�P"r	��V1�\�l�k��c��<E#,d�u���C�w�B�}�Z7y��b煣r������\Ly$�w�L�h?nHM����m�o��cs�%6�л��^7�ͻf��w��=^u+�TY
�
�7����
����J�-������R�O�2��F�m�9�(<G��.��9b�<H��R/<lT�.�Ap��n�T'�@�S��Cg��%+�:�S�� ���ٕ�?����p~�泘+6��`�c^Ncay�r�Úx�IZT^v"y��t$	��L�ǒCY���u,�*�,�|�ɴ���G���|GS�%$~�����\i��UuJ% ����5ډ�Jol\U�,�<�
-u-�?+��W�����y�d�b��/��e�k�2��"�x����b�����.�R w:~v������[�$Gq��$��Aj���.~T��6=9���!�Ri�jA���d�Ȉ��Bt8�t��,��(��y*���/S�����Ʌ(}�`F��22�/
�tW��C��4�.+2=��s���L7-J8e�
�u�7P�GQ�a|o���ܔh�'�s��
o����Уd|VW	�hXO�����ޑ���;�b���݂�Y@R��w�"�c��ZH�+�G����Ò���QY��0(:���
��k�����
PQ�b��D 	��l��[2�� ?NX�]�k���%H3G��<J3JÖAA���t��b�$�͂A�B�������~/il84"��C���<eQ�kT��rj�'6L��;\�?��Z��K��������7!�g5}<�n�M@�`?��vW9�Ng�Z4���[�	�;g�$�
�I]�ݕj�\<r��� �7��G0���;�&M9Kp��3&�#�-��&ȕ-a�V�YT�,ܹ`�[���z�;{o7_n��?�A4;Z>$"'�W�.�}�w%�%��7�/�2�B13oz�����O(W結.	!�߯�,��뵸^��XӆյL�G�)��R��
\\	 ��d�$����8v�w����q���@9֗I:f�%g,�A��w�xZØ^MK��m�q��M9W��.:!��@>n�[ZGw�0�������$/ƌ �<��Z�zLй�����H�.9�A��Hx��`S�O���E��"o����]���c)�0��
��g�@|6�>��&G̹����$��
�&� ,����,hWJ=@���AR�;�Ia䆮��<7����%�����d6����@q��Q��I��-:�CwM��S��T�!�Z Hܫ�G���"'^b2��w��:�|tR=8.t��>=(�`\�F��(s�7)v��pdI��L<���Y!p��{��:�R;��\L����g����v[��dLS~DI`��[k1������Sv5�C-��+�?����'��An�c���:(����J����G�f��ց#�t�,���� v��1�]TA��/�ljz��mJ�7�]
cD���$L#B/�7@��@������欻<nؑ'���
�N"ԝ�%�C���b㓜����@�5�b����ѡ����L����j�԰�g=���]btmcw�G!�P�xf6���j3��.�^�(c��h#��"ϊ���̌��-���.�H���[C��/����)�bdy����(n�כڿ����U
c^�!8������k��5�֮��W+�ˢ/c�������R�9x�6@Q�s����b��V�l���L����yPm��ٛ�L�o��_�g��c�<~S�Ҙ��g��>V����=��t�.���6FO1����N�3E���>��hH��:�V�����Q

�1����$�GY�O��*΢�N~��1ȩbh�W9VĔ<s��$?Ӏ��A�ɑ\�4�� �I[�6k���	�\��-�+ܨ���#`����i�$�,)!��L�������E��{���B0����en�ጅD		4��S��J�'�U�����4�62�g��������9�� r�Y�H/��U�4�a�$��og��/� oj��.� �k�V~����x�������N�!QIk�-�LF��g�j�@�J�
���Q/�S�+�� � Y��fk��RZ�r��PP%�=�Z�C����1�1���d�
�!���ݹ��������]��aN��P�/�o���C�X�}�Y(����c7a�^��E=-MfVp{���6��M�Wm�N�~S!K���.�0���t�f���K�Y��	��2Q6�9�4�J�G����j7�U�p���Z�[9!��D;Q�U����S&3�Z����gEV�����p"��C�I��z��X �s85�yKH5J酽��j��Q�Y5=���Zj4_��2�y�s�라b�9�5�`�����`0�L-�%J]�&��O��AD��7�
D%��U�_����׌�>&+�/_CGS�8j����U�`�%�kr����Pخ���6T�I;�b��`���*�F�n�pk_I1���FJ¶E��Ȱ��w]>����a4Q�cjn�"5���a!LV��V\\���9�Nua�~�Um�GE�CME~���@�с�`)�xV�� ɢ��E}�^^���;��%�.e�8�t�������k��l�^>�K��A����s:�D~���'��۴���P��݈����#
�n�W����o�q�ҭ)���<�R"�h�pQ�O���S���bS���X�~6������ ��II�WSr�ꥅn�(�$6�U>nB�V�k���Y}�v$ȹ��n��%�ܬ���丌|(��K�BQ���1��d ��K1-����qr�Uv�JF�VJ]��6OgWF�G3�#�7F��	c�hh1h&��T3�!g5�d@l�E�JH��\����kƄ�ɢg�?�eݔ�U`�a p�,@
ujIP ��f���x�Yj�^�@��7���+H���É����$��5�,"np��Lo�c��g��� cu�ѶY�Y�߃̕�3g�� ��ٕ@-T��"���pC_��an�

�u~�����Q49��)�����n���筒w�,7l�S`��^V��w'O�Q��&B��pA�ƿ�t��@�� �%1v���׼�1�j��1�pJ
�)�X��ǜ2p4��2j�2��_����ca
�z[e��XP��/��jzIP�J���|l�$���{�d�hH�z4�@���	�����K�+EO�NZ���8��B�t��a�]�E��m��
+�JwC	V����5�z�9<�慨t��;�Q���b*H���j�</�zm` �J�ϖ��d�X��*�2��)���$����e��}�@MwJV���qA&MdI�	����t1[!Q���f����u��Eѯ��'�P:��P��⠩w�iN�$�-�w�+?����t���O�X�7▜�����QA��YS�H#�! �_�����L8Y�d,x^V�-NS��6��Rʕj�y�۠5[_s���LP���¡���V�q
i�����}�����R"#��bm�-[מUR��'�Z���������������(���+?����Ph��i��.�Eu����xz����u��0f-�٫�>��}zJm[�E*`Z�wz�pwݭs�o��'�[4����k�gs>%�xh֦�9`�l~gK�;������;�j��Չ����)��r'��z���j7튊������a��8ȗ�s���a?k�km����ת�0j'�uVKR�U�*&��R�?�l��+�����Uu\1��Wo�Q]o��h�v޿}[Ck�K��^���t��a:�W�O�K����M�;S�,Dj�����)T�^P���T����N��$��r�g�H�����]+�Z��ز�Y1{%׏��^tǍ�_ƺv)�T��+Z�K�b��O�Rn�>@���~��'��+�"V�^F)0c��D֫d�>8�wzE����
��^����d�\������l�ַR��>i9�_���+�f/��#�RIsq�O��9�IpP�gi%�1)�Ҧ��NE5Ҥ��2�OT�f���h�\ih��9@���F�K��A�L�U��>#�<��T?A�9�J�K�t@����iӨ���8E��'�x��I��LY����^����sA��oj�R��6���R��"[Q9��W#�H
B��yd��Qv8�p���7>��b�G߸׆��΁?�+�q�J�K�9�r�߿�kե��#���kz�^�Tx���{n�a��2C�H^`~�i���5�}�]�-/�/�5��7qb���!\R�g%�(�J��yc̋D̗>�4
.�bT���b��eu٭��?Gx�Yy��,���q��W{h�(5�"�2K�7|���V�m-{`���`����_�?���zFQO��!J�~2�S��zk���\i�68J��n�6�~��G�d��l�ˣOL��m&�Y�]�&�?����Ec� ����
�Þ�ͱ�n�-��ɲK�¯�w��%(5	�;�횬��$�ar�f6�(��z�����ϯ�
gO(D�[B�
m-�T؂]#�8�D��_z������^��^�s�;2���4�"!��-6Za ��Ʉ!�s#`}Ur��ӹ���V,���F5
�`�`�,���"�h�e�PČH�=vDo3�����Y�'�2&xXS�/�pK��a|lH:�ߎj�y
D%(�7U1�؝�a��@�M?�&4�Bfc((���D Øi2
1� [�(�9ܤ@��-��Q[�v���a����8���#���E�>2
��9$րY�I�S�_u<�T�8"GsJ�F���QA��˓�ۍ� �݇���>�S��7v�	�4f0DJ�q���6�Dl�|:M2�|�6��I�G'�v��m��3l��;�^<��Ro�3 �n��/Je%�nZw��@1B�]y�0z_]/�1�F�J���/��~��1khp�=#w�{6O (rA��GkA���>��}l��xղ���6
�a�g�J\ƅ��������ǿ8"O\[�ſ��n_]>>����,�	��ZO�P9, o�Q��
��

W(Ƞ�+ICqI��T,����8�s ��L��RP��e�����N�E�v�#���=��"e������8��w�t@
!ы-���sX����k�k���+a�m� ߉-�KZ9�QH]���1*=3��)b���5��$�*y�N5m.����	br��NR%���y���1�	u��~��z�A4�ON��P�5B�I�)"$���c���U������uN�O�4Y��픤�pd-� �D������A$�P|�9	�3`��~~���&8MN0�d0��\�Q�Yl�j��i�f���'��F���7Ǎ�?��Ǐ��_�5���+0
ɉ���\##?����|$Y��U5j>j�ɡ�U=��-
�(��w�a��!�j��]*���͛q�u�E=��1&�N;���Ȏt������N9�[��s��4��v���FЂYK��oC
Ί�D謎f9�Eece]��!>�{>O�A#�ظ���?������Ӂ���D;u[������ϵf��:��(ExQ_�������;�WŐ�AX�+�/-���;�4�I�QP�����Z���#�듾b�&�J�+JC�c֦,���S�fv=^W�lh��1�Z�7G������4J�2Q��59<俾�}�P܅jw�����B,�(߽�w{[�b�z��0꾧\��d]�<�3�,�o����b=�?m��;<���@n��[���w{p7�M�M��q��T�WB�N�[O_~ �W�a1sj��b,��ɟ��n�9�u?�0����*z=[+��(_�I�f�Y��Z������p��/,�U7:�DC�qO��jr)2>�[����@BKS>��rD. �G�ك�_��#��P9i�*����*����q���%G��:�8�bt4^ȩQ�ڂ�T>Q.��R�[ި���շ����m�R����]D?��F[g�yMXMe��[4��`d����s����Erha�pg�I�����h���D���>�j0���JfDH�����Q�a�ŕ�P�kOvyx������*R�9?��ܐ�J��hV��|m�!S=0���jJ��äg�`S2��@���d�0�'m�-W�DkSܳ�@	� ��rpC{�(��ua�.!�������"`ZR��������(�1�+KȢ%)T㔊����9x_���A�I9��G]|�[�l��2t���UD%y�|�2���r��&���v���/w����޼�}��vmm�	�d��-��)%KP4�g3�b�bI�?�@����*�	Wp��#�����"[�#q[G}SÁ���!��Ӛ�W��r;��1G(�>���&�w:c/T���-F-����J�f�Zs�p�L�&�e�9����:J�}��f3TQ!^SU9=�҉�I�z㔝E��z<��K��%SLڒ���� u.�:�X�dZo�g:4i%kRU��#��q��X����07��J��]V� e��N�i�V~hM0޽՚M|�~�����!\�k[�>���m�e�-���4�d`�O�_
"X����#	���O[c'�L��B���ŕ!�̳0
�`�Yu�t$�E����'�4�-^oup��\� ��RP]���>��VI��G=�@aYu���
Lߺ�����g]���M��}�v�v�ׇ�ϟ������jÁ6��߽�&����/�pʸw�����q�s�"��Ve��׼+D�{W�s���=��Ɋ��Dحy�2?��'�X�|2h�;�]�`�D���D���|#BrĬ�����A�	�_)�i�pp�^X��M��MR;�Z �r㋶��n���9��7(��H��[O�x�'�֋���_RU!��n�9����/�&ڮL����M�u��ԅ/T���*|i�R����-U�e�V����7���U��*��*�V��V�����
U��Z�oU�[��*|g���pW�Z�{�p�*��*��U��
���Ux`��C��*|o~P����T�oV���w���V�����
�T�Q���v��n�����|\�������h	��gg���!�f!N�ݮ����\c��
�{i&�'o���n�_�t�����R��4У�����f�z�^�v/���D�Ni���J':��t�N�ʗ��_��I�����2�D���rË.}�3�0��ۜ@���<��|�Âr|�J����7[�]�d���7:�Q�h����c ����ok�t��
Fpc����0��͜}s�r)��Ւ��,β��F��azu����	�2�`Srd_%���h��@�ZG;����4�{�7���"�ɛ�� \��}'��ۀHc�zjm�a.u�t�<ӊq�cJ6��Ye�7�	VM�"&Ag#X]79O	#%_�n�<p��G��8����2��Q���<�S?t�z��i��p��N�yqP0�vL{o0�w��MA(6�f ��?H�Н�KLR��V��'�,�+�0�jb�e�>�1_�i�7Ӄ�i��*�E���͋���+rsve�~t�xH05�j�c�D����J{��mE�1{�,>��?���̞ۏ�Yo������-pJg �n����u,YW��S(��ߢO��
��w�O�?����Lj�k_A_����_sq�أ���p���TY&� �ľ��(}��رz19W�����
��>�Xh�|��5%�:��4�bzfAz%��.�Y�	z��Ѕ��^�v�ez�F��)�7>Ul��AE�ni��G����U?!�;�;bm�h���A�1�η~�:}�E��.�4��pp/$�Ĉ�1�;����ź��ViC1��h�5U<#N��i�g�n0
ݢ0s��K�T➝=$n���O���SMA�րT���*��c�rOr/61r)�Mqo*AHܧ�%�dW��ʺ5��Ȃ��W(���kr�Sd:�p�ɾ��׊7�9�!��_*��N">�c�u75p�i�Jz��HQ��g�)�=�C��~c&GݫU$�e����^��P<�qI�{��,�jC�c�t�y ��U��!
�aV~n8��e�������_9�����P1��h��뾢��(wȗ�懼3e6g�[%ύ��맂)������o��2H�����h����1�g	\����k��P��3LKP�"��X�R������;'@���>˴]`��^LrdycC4���:�&����CPC����� �y6S ����FIc����Q�ֵ�q�N��FCԫ��]^Z��ɀ��J��ő5Q��Y�\"�)M
���b�f�úy�V�t���F��$w��]K	-�*%���X/�U=!C�%�O�H�6'�5\�G����f���h�b�� �U8��^џ�:�l7 �&�z^;V!�7O����4`bz]�M�_���0.�a���Y�����]w���J*��	�G?�������UP3j�Z  75_<ϓXw�o͖�G@����:;W��ȑ�n�$��=
��\	���Vfo��6��6�>�'�oښ8�ج|�׭h�y*�Hx�4���7���9�jwXIc��!��-�';J��8��_F�G!��ʄ������$�9	���?�����
o���ݵ5�D�5�
�MgF�+/\��Ǎ��N�z���� �i ~��D��12���ծ�E���ٽ���u�Fu�1����vL��Y��ݽ�}o�[w��� ��ݪ���8��}���p�oG���EG#֍�Y�����>�EA��T�����@�0�#q�U���^5�."�p�& �x�g��V���!��b�_ǛgO#̪����
��p��=�eK�����JV��N�-�3~>��*�x�	�+\;��l�WƊZ���h�4����!�����OiEf�D�2Ɛ�L&к�Pz�:��
T~��o�����I?�As�.--5��6�/�W�vB[�Fg�P���_�=��o��,i�7�{�B �Ó�Q�;���/h���_���s���D���)u��;�W�� 
������n��w��d��&tg��'>�dt�CG���>�pt�C�вd��/��5<$}dhpA�9Tz�k�gk�Ը�
F���zI�X;��%��V#%K�M���=P.܋h9��}@�R��V��CM�'c�??�'y�P�Q��^��tp�UV���LUu�`��$��U1��1����M�Td���1�J����h��5�{�E2�x}c)�1cjK=u���8l>�����f)�N&��wr5�M�Hi�7��y�>6��_���*��Q�\�,_�,c<�u�$w�u?R&�����%p{����/�����b����M�	�:�G�����T'�֒9���.�}}���tL����m�ܦ�
�����TΘ�i��I��y�^͇��N���d^\=^����1��876�&��
��;�J��չ]�����u���'E���l�[���6g�#�6�`vv�ca��UM��j8
���F�����ͪC(�r4u�'<�
��)U���r��Z�l���s�6RQD%�q0�fir"��EYw0*�p^�\s�{t|D�%+�G01�l���US?����I�&���N�7���1���1c�Gݦ_���`D�e���EƑ%}�Ae�1
�T8��Kνd�U&Uw8��p���S��4��$�"���e<��,t7d�r�?��)�QT�e�yR3;P��cա�w����[;��G�Fz��N��dЛ%�A4T�8 3_37łˈ샥t���*����uWQ/�Ǽ�k��-?�Gl)�:�;f�!��qb��͐��iTG<������ �����R�&�r�y�W<�X� �
�bSk�#�����Y��B������\�Ӳ=9����}�*=.�~�������|���*�nm�i����;o�n�pYVG�&�>�:˅7!W����Kq7"�hԫ�71�t�+&#Wazj��Y�:]����Ry?��dg^+0ǘ�!��e�l,���*E!��PZ�"�gqzp���+�\l|:����忂z��ßؙ
}\3���$D�	�掤b�ȗl�=NRw�.��<FߩXy���J���>�>���ک�����+�K�j]��x��k�w��[1�FC�z8Ar���/�[��L�i4�IB�X'd��g��y3
���Q���O�t�A�!�ٜ%����>$�	����3K���@�o�
eON�x{U�$��iZ��s}p���eޒ��]�׼�[�q�̥eK���ba	W �]���ǷW�h�C�
� &��&����/	��׃c���A������r��PK    X{Att�7  �'     lib/Carp.pm�Zms����_qC�(���v:)�Rb'�Ķ\�M�1ɋ@���(Vf{�ݻ �(�~��cw{{{��{8�T,ŉh}���j�:X�M0���E&E��*̇���X��SI���O��_�_�#���=�������m��1��
��,WA��U��X��
b�A���fy�,OҍP�yےT���\E��!`�X u/�C��A���""fI����\{�t�%t<��hB�$/Ƚ�z2�a�RҠr%�+$(a�&��8�"�U0@kYֵp�[L�\܉>l���(��&��X�~gX���	y3�1���=�;b`L��C����Z�cE�t�Ɏ���9�̓Y�:1[l��Y:k��ܼ`�<'Ç��j�v����w���Z�ʠj��e��FMy��x\�nLCg�=U�!�
Q��j3{���@}J��@x]M.#qR;��Ǡq�B�pCc�`�6b!�(h*�osۗI��p͔�lH���
�7�w�s�c%Y��狾YyY��2#%�4��|��`�����#P._����q��hpu�	�?Y�^:��f~k<��t�muQ���N�X�k�D謝7�� c��Ty��GC�z8�����M/����*�B-�fU�5گ1��ѐ��t�FgH�$�H�^�Z�}35/RIu5�R�''P(�Za���,����\����=��ɭ��i$>B�t�\�n���"˳��y��i�#��U����M��[IA�Cq���
A1'{�UrM�U̴�����Q.k)Q��C�O�Y���33a�	rhW%*�n��y��{��B�ƴS����2�=Z��2&D�R�%yax�#}D��G����~
dZ�� �rx������e�`�	y���Z�b�D�6���V@�٥�;����p�)��޸FC�B�\_3p1��;��T[Qm�ʈ�f�;��tRYq�z�)�E�bטx���m!s5�,3�G�]_-��m�
.P�}�����Q��2��]�W�
�u/�,(��t�{��#ae
$��^�ٶ�f�
6�e��j��)��m�}�]Z-�)ߴ�!E����/�}k���5ޔ�[Ad��V�h��ȋ� 9Tu@7�
�HZƂ�PY�=l���3��E���H�w�?��+��ҘJ9��B��a��A��iJ!`��/^��:N5���r�� ���T�W�s��� �,�
����4��8��V[��T�n�/	_�)5�)S���[������F���pCY4��	�*6�J�p�1<��a&�P]�C\4�j��tm��	
t۳�Y�D	��V,2�KL�_A��}��۶2��)p�g-9�<2	f��M�i��7�i�#`���c`�O�c�>�Ȧr��W�U
J1S� ȣ�w
G�y/E�fI]u�'0)���q
K�!S���t���+X�T�U�YL�M�-J"fTc�����	�8�).�A1A���(�6k#E�^Hr�3�jä Y8�Q�L9��9%�BIm��s .2���Y4Q+�z x˥b�൙pq��2L�0ϩ �k0�U5��1DiL=���^'3f�+�j�DV2�r9]����G!ިME5��dF�c{���(��{I�@�OX����7��-�欆w^2��quy=A 3b�)��!Lh�l�JXb��f�p��Y���˥E��X��A+�Yt��<K)b�0�@��u����:��<=�����=���U+�8yG�@�T��gW��D���\ѵ]Uc��D\f��51�i�yʄ�'&��1A������YR$�J-U����?�n�� 2����_�bNWz��_)�΂6�N�eY�����)V�#�l6�VLh���hsJkl��#y�HcȽꎝx�V��9�r�h��۸x��^Զڟ�l�-첑���1�,HPQSJYH�C�pn�2Li�G�xR5v��}d;�KV�8ٟ�Rl��5��Q�W�F��wxl3���Mq
��j�a�!˜i��s�Zt�;���Z�W�7T�~mY��k�V>x�Ӝ˚��N�J��H���h�9rz%�Lچ����0:)GZ��f��[8�0����g��?^�^N�N'��3ڂ�>@Xp�>�K��[�=طj5��y�,��j�q-�U:���Er8|9$U��-_=�1�I0n��-sC�D�=v��ݜ��!����j�˱�M��Ŗ�'�����K$ ����B傊\��<v�oЮR�X����_PK    m�JA��?��   �     lib/Config_git.pl���
�@��{�@��Խ�A�Z
҂����6؞���������,�O�%���!"8�NE^d1Ȏ������x��$�
�_�y}Q��li+�r�� ���a�
ƾ�=O�U������Z(��(�8©��7�SBA�B.�_;�OXڻ~��5t�%�/Б��O����/��O��P����
�Z����:?a���G�Y�>`"�Ng�Kx�2�� Ȓ���A�ߌ���r��8�=O�?����Kx�k��Á+�,�=����. �^N�|�4'�f	�9r�9a��'z ���h2����&h�?��s�9�`Ƙ:>�(+���68V�4�f��P tC�^�.z��x�PH̳�0`�P�$#�X�Պ~�U�GD"��=G)�������y�P�X��%Z@�a%��m7�{�+�o�U�:9��#j���3�6�h[|�b�K�u����Q��Y��ݏ��w�!�1�$ȋF�ç;N>e~!���	-�؝����?uf�{6�]6M�nl���χV��[�����ʜ�d��8���OsZ�N��~�t�
x�Zֿ
�e�\sZ$��Y:��Z����P:E��Z!FNѼ���L�!��0τ�!3�R�x9K��3q ��C�u�VQ�!ဆ���`���D6̩vpq�8)�������t���$�d9�t��(��1��F^�u�Ya�rT��\s����$�'(<Aq?��m?r�$��4]g�aQ�W��c>SSJ�"�tR�|g��}��SLr�iM�.#���P/��zJ($��V�.Ie����A�GZ�`�N�h��c���T�AH�O,C�e:��ހ r,*"L^���6=�A]���l^�7˘��p’�I��n����$�,
�]�c�֚�&=���/�#��|:8��򧣯{oހ)�o0K�[t�X#�?7Y�9�FI�?���_%��
-Tэ�[n��^o8~�������޸4F�@���}y.�ML0'�5��J����Yy������i)I��D�mL�D�>97�j�F��>���0�#!>��V�pA(�Toy�пB(E>���B�6��2��������U|׽�~w�ʳ0E���C� �_�˯e�Mf��Yy;+�y;������S���������7�{s3ꍍ��xt�n&Y3t���_c�{��W�Vߥ�V�/�̌�梤�Y�K�q/J��~6Hx2%��W�;�Ei�]d3 5��3��ZR��g�(������>���
`��L��L�,#��7�3#ī�e��e��eB�2EH2]*2]2U���%�-2���?hI=������0��pQj�ɫ�z�����tA9��Ƚ��JO{��3ҽW+|y�2�E
-Sr�����f�b`���~��h\%��Z�T�O�jB�����P�V�:b���u�I�����et����Da�B�v �*���=��Ԉ@������z���j\��-�.����������;ȶa\����*����O�]��>����ׇ����O,��?���'\YD��$*
���x�/�u�ׅg��:M����q�zxȗ\��'g�j��n�:�Z��n5���S�ܨ7G2&g���è?�׸�O��j�ٮ6��j�ր���r��0y��,T��o�����-]m�*�Z�<7�F�}4jUh�@!]�X�Zo*�������i�����Z�ک��?�$�X]	��r�z��HҨ�x�jZ��F�Ձ�_�N�z,�]���Rk�r�q=H��RS�I`Y�v���q�����[=���RJa�#=�������%�iW��zR��_�	tm����$@)���r��`Z�ޙ�E)�Y�H�)ɳ�B��@8-ϵ��u�d��De��'hhA[����Q)@�#�E��i(��j=Ɋ�>i~wݱn����G����k��
q�ԛ	�����
IUW1 ���;PW�6t�z��:�2�|���g�	'��zK��ZN[ͳf�U�����)T�����c���Q4��Օ��.������/�
��G$~!���F��F��j���:�ӔDp���J6:Z.�,^��J@f_h�j˃�R����g�a����HS۸����A�����껹�
!��ۻ.X�׽�C��v�a��s�;�����?�n�#���9� pD3���G�Ǚ�;��������� ,��X��VSȴ<���wc\�?]zן��( ����F
�TԜ	G�4�ZJyD�E:(kW����'r	�#K&� -�0�*&��l�O�M��A�o�j�Z�i i���.��F�:�Ex/%�̄H��4�{��*OM�IU5�-�)�{E�IU;�R��j�Ϛg���YK	ڲ��j!T1O�����
T�"���rV��Z	�˙��4�$I5UNvf.���.UUv��i+E�t�e'�B�e+Ϥ]��3��l��}
�O�V��X���GW��V�A�jT�rh:V׽�O[r'd���f�i��x�I�����xa�A-�7ONO���}Pf]m.;�Q1��3�T�;�a�KG��	�ar	�?�b��)
�sG<���R�@�TL�A�8	��y�ҞlVѮ�_WW#AE;������ބ���4�����g#�Ը�|omnPZG���GǇ��a��c����V�d��7E�m��	��i�4��gؼ sr���W]
�<���m�z>�]���8$��p[F�0� 0;�]-�k����j��T�0���hE��T0̃x��~�wk-!��-=G�ہ��ٙ�ƃISǂ��_�B����;I҈x�\#�	fbR*�;O���jU�o�K�&�_�o�����H.�_��2�/���g����j��U��ʍC��&�BL#�O�P��1������Ȳè`YЕ�|c��uh�'��Tpg6˥"A�00�Sc6���4C�K��T"�o�Q�\e{:�O@(��0v��ӛ6;z��/V���~;/�lo:��aZ+ ������J/O��E��<!���������0��A�X�(��7��@��i�R��-V�f�"3�fb���d�̢)$�X��}��L$
� �t$4��_CA���=��#zf\�u�Vǲ�B ��`�ѩV9�4[��w��ty2B��&�䇠oE*���K���%����̇��
#3��u�x�l:�*uu�\z���h\� ��=4��aj����DvdN���ʹL l�L3��^���س��c9� 1] :�r;�B2�*�@��s�G�>{��iQD��s�e�a� ��!N��͹����v���a9�K/S� �ˇY-hY��ּ�Z��d��U��O*ǳpa���y�{+���r����A����Ѩ����亟N��G?�$�dK�ee�8��~(���������$�g�R4�V/q�h+ЕdS�΢�-��MaPQ�/��p���$�c�#O�w�˜ǡL\~`U��L3��\�!�F_Wk��+�l��t��,��:�:�p�j~ۑ���a<A�Yl����4�@!����CRH
��&�����͂�$��+�1�4�^���EtCݒd������sF� �3��g�>?-��<AzI�s-�!�hi�������i������0$�rK�
qN�x�2X���ǀ̠acd]��,+�|wj�����h��ox_���V�
cI%
�&�B0ߴAAssmu�8�d-�P��4��u�A�,%�B ����ˇ���XZ,���ّ�\�����pi����[F�8^۠��Ȕ^�T1�OnS8�a�����SH�4��+E�B
���ˀ}7���2q��,6
"}1��l�) �S}�!q�(.�gc���w�(ZQ�P�Yfu�p�*�[ �;7� ;�\\zI������w\�Hd,FV�ąk��E@��e���e��O�����ȟ����> �e~q��VS7P��`�.�=�Nƍ:]ߤab�C�`qV��96�~	�+��ѝC�T�P�җi�е�U��n�]�Q���Љ�&��ρ��Z
�{Gj�A�9؈d�k[� �%���G'�.X������k`z5%ސDoʫ5������p�ݶ��o��@&�m��64(�K��/J�<�/��ߝU]����\�L���q�7%_��Y���+;`�x�l��!�g�����7��I�ڙ�aT��nI��]��<�����kd�|+��?AWd�'�c�+�\�����Z�RW��5��~�3�Ē
���-��e��O��ӹ�������GA9W�:�)�
)ٻ�I�Ru��ac��(�R�Fi��(%'����^~ :ek�v�Xɶ�c�r��weZ��=՞�$�=J_��%�����"�L}OTwB�`}����G��
!���褛��Eb��Iq_�a��4���@6���	�����S-J�*�a�Vz�( ֩A�N�HUϵ�y>{��������Wo�ߍ*�W�9��6���u��}��U=�]�?��ٗ	���גШ���(�K>C0�؟���1��Tto{&~B���pۙk���"̇�������v&�m~k��N��t"��$��p.�
��Y�i!I~�>�@�ɉn��d��T�)E�^�(����zٝN�ǅ� ����t������y�T�bqS�bK�HP Ӊt��!iE�ϒO��	�"�Tp0��LEI��DJ�v��<�&q�I��<)5����6�Vk\�ˮ��o�v/�G��P�S;t;�tK&;��(�*�ʡ`��>Gz�6�>� N��]��X%w=V�1��I۹v��g����Y_�e ��j�h4 )n�O:�P�ۄC�bRǢ�Ӕ�d��rO?�Jo&����N�{h��]�
��p��/�����E��ϰ���f�VnwC��\���M�(�W>_��Y�Q�n:?��A�#პ�z�w*�'�v)a"4� _��ڊ<;�4���  ^��|�*4x^у�`�_������`f͔	�o���*�ȇ_{�Or�X6���n�?��!SI;_Н����^������_/�A�e�8�}k���������6 �t�O2���E �/d�`[Fs<��� K�~�J��4�81�B�{�e��P�{
�|�~��W ا��Y�U$��]?�6�:��k��M��f��f�n��C�΍��S�]�eM��.La����t����!�	�w�)_8�C5���`iD���z ~q��O��?����������N|�0��	 ?������}軀�@TH���nܿ��]�}z��T��Y�}�>=;S�qt��u����@x� ƺ�ݱ������B������@n�V ���}���O�w*����0��L s	��p�����o̽��r�+zӛew�����%|]=5�hi=3�l��w���(������<�)(�9$��ёa�D��� an^������p-8O��x�<AX��	��e�@�I"
����/���0��f*�I����?��:)�ܤ:s���-w�Ž\����x��==��p������`�`�>����]�t��cA�i�Xc���{t��C���;6���h�����]�\��{`7�?��h?��~����-�x���>ތ��ޏ):H���?�z�o
E�_�h�
���d]�+�q����5p�dmf�kٵ�2
�
B4���1o�|��9X�A(��#��3|�J���5�C(�I��жI����GG�ׇ�G\��M"�VZ �򘁌r\�T�7|�p����6�pe[{o�@��������� �J�%����g�8��ńpf�/s3� �%R� ?�?6�-P�I�Sr0,f�8&(U��9���/�߾N���~F���𘮇+$Ld���-�\��;)a��Ș?�z�+�L��"�l���}za�i��\��[ڦ��yn��u�y��C��]t�_����8ГF�0h��W�����K#��s�5qN�"����i��k+��+�^�tQ��UxCg�^���%��2�-�dk(�!�+�*�
���(�{C�眕����D����F�4�
͉3,
   lib/Cwd.pm�\�w�6��Y�+Y��Ԓ�7=+��8��z����isN*MAk�TIʊ���f� HIv���te� ��<�������q�u�F}��D
���L�,O� ���/�$�e�~]�i&~_zO�N�����oNޞ��Ó�D��÷�G'�mP2�Şh}���QkP�]��lx)�,Lb4�>����#��Γ�aڞ�F�u3=�x�r$&2�?c?��#p3_dS��6
O�!^�\?�S��Z%���U����TmcW��jwP�!M;��[%ɅX(�K}`�2�>M2����iW���S9�i�aK�T��`$�_��BP��T%��9kT��U��F�y��5Z@'�pl�d�:{�^β��hPg�Қ�j��f��q\�;=zy=>?:o�����čK��U�Tw��M]}n������-L�ɀٰ`��]��,�������|�z�8��"��y�9d��G�B~����X���~?X`;��k�# 3ROƌ7ڊ���v��G��r�m�|�z~xp�|q���x���d0|{H��u#�~��`-Ob����g��z�@�qk�u�Q��/N����(F@����.7A�3G���EO�6J�Cb�)lEȑ3�8<�q����:���v�]B��<���?���$ޟ,�pm���V.�Iz�-�R>��xu��Q��d.Ө����#����=�ݝ�G�ǘ���W��`=5��}b�������_�t�]���*���{��t)�x�-ZE���C���<Ir ���~�Q��"S.lLzE�)h*1�o0[�Y81|���"�H/��Lf���y}x�������7b�{�.�H�=�oj�N�Zm�h���gk�T�[ۤ��ƶ[��h�4�G�lS��m�Fb��%~�h�l1�*h��q̇њ��gz����3���\����"5v�LJ-e��4mXHi񺇉�{ha�X�c�vkѶi�fW�7�ݹ��������F���!�B4�;���I������&5EӦ���Vֲڼ�����x�����+�&K蘻���o`����`�ĩmU�&J��"�5���"���������'g����>>��`�<��Iy�a<b73�+ҹ��<��\d�l��`��a;�@�?�P� C
�y\A�k�|�-(���X�f����D�^!C��L,b
;���0r�a0C�2�S�)#�<�^�wƽ9�V��"K���}2���UV<�՟�����o�O��F1\�Ot�(�%ԣy ����%6d`�316N��a�_�yϐ�V-�r��
c�[�8�Z�	��O��MRS��Ŀ�ԙڸ7�Ey[+&�	(BzKZ(��}�Dś���9�~�p$R����͕��+ʭ�?��Z*��i(�F�sr��{�����\�X.I�Sq!�2��F�̞� �9���U�9��

����ء,�� �	�I"��b��_aZ!�QR��L	��@�C"���F��[���9��LeRE�1�z�)�����
���!�2NX44��eV��= ��#��ͣ0�h��U�|m9E�.�{�I�9$h'jV��c"<
�Z��p24�ы��#�|-��.^۔�����̒�-ͣ�	?��o����l��ڶ�/̩ ���x@��^�������݇"��L�u��ZTM��>$wޟ
�K#OP��i�n��C�;Т�JU�����6�N�b��ؔt�d��8l
f2���?�/�t������N�Z�V[;�gW�_�4��?��������q_c��1�)�ǐ��"����j�3�11��L�Ef4t���4�R���W�}(J
���:�R?a����X�L���J��,���H�8��@�
ԯ\��'L��uzOI,x��.l��<?z�֥d��Z���w�Cj����+���Y�}�P՝4��w���b���j%�4z��="��@�D��8z3�
?�5�|D3��=%2q���T=�tM,`�e[����.��Y
u�FǺ,�t��u|rv��cBdo9��T}?S-?Cu�*��+wdr�>�v�5K2������#sh�5������ݼQ:P�:�;w5�U�  r~��it"1l
�E�"Wx.CJ?I�b��w,�$���vW�(�{ᖒ�0��)�[����kZoT*�R�%�%�.ziz��+I�CXSQ�������O�9�#=e�H������ G�
��Ǵ#C�
��u-r��J��o�-(T{���oM�=q���v���"4`f�kI�u��1?�7�'Ɩl�.�Fʗ���MtSS��o���
������O��MZL t(<�f�QMo�]�QO�5��-��+
����N"�#�/{�3�F�r\qe�t	����<�菿�;\����OG�D���F���L��VβL-uP��I򙰪u���yŴ{%{��a`J�ϥ�`0�Z��5���ܖ+���-��!��q**��F�����(���0���pX'M���i�NQ3��u���@�R&ɿ�NN����/��@;�|�e�v���4j�8��e�dQ��+9U��ŭ�_�9
%����j��Sd��Y� \ܕ�݌Nr��2��Ī7�-�1��%J&!�$��P���1[P檓y��4BՌ}E�.b
���0r�u��]��ރ)Ua���{���!�1\	�������m.�ݝ����r��������Z�}t�o+U���"eΤ+M��æ��Ue0�g[ޓ�}���m�iD������fo���ye�?���O�����}�t���Xv�>���]A�i@�շF�đ���n�m�:��y*�#��`���SW'�e��,�b���N�v�W���
��[y��ªx�t��/��Z�+�G���Y���Zcj�
��P�fe�Ĉ��e:��\��\�X�T�[�����ʳ]�0�����Rd�/��M�K"���G0�OgD(HRb�H�{"�z��?�-,�r�"߁�L��)��W6�����$v��ڍ�]I�%<@Wć.~~*y�p��-���xPg�{��>���z�Lg����6�]���E^.��JW�z��EC���v���Sd�����D\�J���K*����,��Y���?�s��/��l�)^������ygM]�8�9Xs�!���\�A���N�,���;�{`^;q�D-���:�~���g��UGJ�
%��Y�?]Y��?��-[z��W�ByB���.ܦ�-�U���� U��}���k����5��W�鈏ͻ�߮�w�����U�7�]�9�.��=�E$�5��Ub=ӈL��U�0�_d�\�7rhQ���s~A7A�+��h�������4�f��Z�TTǎ؋��z)kc��F�z��7'�~���v�(�Y��_�2Oi]'��2��^�N�
U�Y^���
��$�%"��	�h�T���6��t��l�P)y��鬘�
�Et�R8�s����%a4�
&��k��/yMJ{r�5MѸ���tpF�w���p>�`�v�x��_�?��a�wxrr������T����Y����^���h�gy)\��d	�<���X��q<�'<W��O,�d�b�/�M��k�e�3	���N�[۠��R��ZA6y(��(��1�0U�G��O���{��Đ��z����n@����!QN{lF�L�Z$�cM���Q8ZpZ�@�7� 1J�B!����z�p��Z,q��	�43K�2^k�57�s����1v	�UiCU&%���J5�U��m`�}]�EC�<�c�ē��U��4wUAU]:�� u ͠�2Hj��23�ʲl�Ƃ5y�h��(�P:��x���@$�),�*�S��k���o(�`���y48ק��=��fdGi��V6��pB`�pNJ ��}���0*a��J�*��-�#cj��W)l����]�΁U�������m%Llg�i
�Hh#=��y:�����Q-/MI]5'�y	c �e�
��J<C�ńH��z

�a��`G�`�0��.ҩ�#iREx�M5a4�����<�Ձ.�r����Ƴ`�i6���M~��DQZ�}�4�j	�Y��FJ��`���AT�y(ЄM9�v��@c��6ˢ��Z�12t6��3ˠ���,e�x��,�Lci� �,�_�r5	���KE1:d$� �g���o(�t�O����Y����0H���BdY�;��
c"'iv��c0C&��)��|N1��mA�T����,t��@�?W��R�F�^Z�e>�!8�TD�Z.�u�	&����a4h�QA��,�����&T!�:MF�X�܊���qgG��Ϯn\�_��:N�3TM�,�;��ͦ#�0�g��_�f�*:_��t6�����r&�[:"*���\��Kx��$ 9M`2��[���5�ޛ�`�H�-Gj���?�~��U����;�5.�=���
 f�q��!h�MD?g}fM`81"p�h�E�����6�x\�~v>�n������� �gh�� J�#/��/hs�!n�aM *�j���o> ���͑
�N�>�]�.���ʮj9 ��P�X�P�;�v�V��4͕-Z��14����*�?83�Hҏ9���䄷tT�!@���'|�2�q�,͓	�؝6�'OX�U�-�bbx�]cQ�?a��/Sc%3�kF*FdC,�VM�潰U�d<|�����cJ>T,��h�^���-p�$n
ǹ�qR�fv�
Q�j�X���`LP,|���MO�lmL��Fx�L�Ź�[�D<��A�*ݲ@��)9���a0Z"U�a�g(���0�/��p\%7����"y%� �w)�t�yyj-�x��=��X��3�4u_g�Ԥl`=A�2�� bM �.�#�!D\�%�D ��3p��]�(uq���W��j9���b�\x2�S����C9�IE���vnK�����%�w
���;A���+zV8����ߌ�-���V�Q�.? ~���T4.�h�)~D���YDhu!\F��V�4��f�Z�P�7㚔Rd6�U4�b<x�1�p�X�NaV
���8��X���H]Ŏء�a񽂤���� ������>Fg��P�_�p�����J��=�؆;L����]5LilT�_@�9�U�	�)
ӱ"��Ć�Ul�`��^�K�Rڏ[�����X ��SU8��Ά�]P?~S��Y���p���9��4G9h����q��XK�!���u����2����N�Z*G�jO��ܷXn��-����Rѽu�v�oE"��҂�n���Vc;�5�%bp.u�R%���;�U�G��Dp��e
�_ɩ���f27�:����\c gB��b��S�`��rΝ{Q[����!M�H+x]�8�K9�]�-̖<�USm��&�`ROV��Y{K`~�%�%^^����no�ϚC�`ۅ��4�)yd6��p[��%���'\�k_狢����v�����
�����ahcStHa/��)��X��2���Vɡ��l�n�-�kEۦ�o�럦Y����I
;�m�5��mow��43�Ǆŷ-d������x���b�!�:��2G��0�.-�=ڊ�잂����+\�|��9S,	ś7*sM�pY:C'7��^Fd&����9M%�2C\��S�UW�"@�;I��8g����"U�!s�-�|��ڛ|&B�P1�	NTS�g��h�]�*���V��p�@�p����ܚ��d��=�W@µ�T����8%�`zCٟ��h�հ0(�\P3�����O�@Q�I+
�'O0����sy(�P{��}��2*�}���$d=�A���q}ɪD=�$��̿w����������NB��e��>���'NH�)Ui��P=y��>�[
Vy��n.-�:�2·��
kd��j8m7�*LB��Wu+ő����B�S���0R>+G
�x�v�kU!�#a8�B�u	*j���AC�����T���T��.�QF�LI��E��&�8��T���h�ԃq�)���=e*l�q���|Ն�J��t	��ْu��@������{�4��ݐ
��xs遉�<G8�k�����_}c��ܶ�FAc>���V����Y�����\TRL�m%�M%̃�t��e~<����U�U�����ݜU��ۗ��s�� mW��>�A苿q����b��>W�=������/P���Z��n�!^�	:��Θ�Il�(�����m<C��ΛO���G����BG	�E�d�!�U[�rz�3� _�q8��i+w��p���{M.g&����d���4��]q�$�qo��Z{��Qݍ��>a��v�LO[W�Pu�ʤ���u��J���-���]n�H��e ⡟:ĕx�#r��(��bO���m�+��(�0�=�0NU���g���<��+�P1��/�\͙���O{�~ޛ,��+����G%�eޙ"%h_8�/��j�A@�d$+��C8tQ8Z��5^r�������6���6��g��D�A�>��_:*��[kS
϶�.����v�4���mUP)|��Q��Ӂ�*��n�����d(?����g[�k�w7�]���iƲ:~AP���hq��V.�wy��@]98�r�E�����r	��A���'Dc
3t/R�i;
���G%�WoC��&Wd�d���]]Q���Tv	U ]d�Bd�@0�z��w���@��O��G���a�v�w��C��3�bY�ܥWuƜ���|�;���ǭR,VX�Ge� �ť5F���t�2�å	���˝��ۭ�z�p�m�X�����p����_��&}��4��	:mKD?u���`U�&t9��f���������lu�^��
3�}Fe�*����8s�3	�C���x���������'͠�:��w;����� ����>�����?�:��N!o���+;���
�Ⱦ�䞻���{ɗ�ְ`���ޝA�g���?���B1������\ɺ��O�D�����_����^����G��X����ݏG�V�'1>���ŋo�sJߐ�����7ݻ3\5���!�Y1zAHU�"�"6��=:��e��
�$���6D��c��>���w��(��a4�8���9+,~��c���4�]QY�C0��9&�a;1�O뤛a-�oN���}�dBt	��@X���CDT�+�MZ��;��x���^|�~��
�T�����qP=ϯ<_��t������\�ͫwusz�=�D�������o�=�>��/PK    X{A����  �)     lib/DynaLoader.pm�Zms���,��+�1@�"��_J�ɑ�xF~�$�N��s�$*�� Q����>�w$�f�dL����}v��4ɔx-�g�L^h�b�/��C�Ne����Ŭ�K��?ɗ���N.�[9W�;���4��;��2�	#�x,�2[��NoE��*Qjq�镘��.�k�j!K��bS%�*��D��z9Mձ�V%~j��Z���S"�S]`$�B�P��i̔4��@�r����<C�X�����U��Z�"6BϘD^�ǥ�"�V��o�.�U�5dJT&L5�+Cښ���L��D�U:�w��J)�kp��KA$�31KR�\�:��*+e��l�6��h�
eIh0_��/=�N�÷U��d>������j^A3����?u:o�߽�(:L�~<��z��x#�����ǝ�N�����,���UF���V�QYH0�T��̶��\��t�:�8������������������Q���x%�,%���+cQ�sq�_S9'�fJ���LX�S��]���$s"0MJ3f����Z���Y/�:5B��$eQH}���$�á�If�$�_��t�ޛ'�[��+��������S��,���8���������oR�ܶb����ձP���8�U��G	�,)�w֙�X��#�� !!��R	�-�z[�J��_j1HqP�5G�7!px|��pI��	�0d�L�rv�A�{W1�����$B`zdـg7|�Z���ݩ�8��`�h1)�T��.d��{���i��:�9�χ_W!�E\��^Ӌ�D��$��
N@�P�VI�&�ވ��s(2	o&���R��jtz�&��⩭�6�d7�\��4��XOrY.��n�J{��e�d*���Wub��m�qC�TQ�0.��+2�1�ҹf��O��_p0�}��+�]:�!:f��jfj'n�)P�f�ԟo���ݭ�
���X�@��9�)��&�o
�ePd��g�L,|d��\�w�K��\HòQ���:I$31�\��ܨ�.)tFq@ɭ*��E��ɒT
��e{񂋞�O���Rk�cߕ�g�2rb�{I������|(~�|���b-j6�E�pϿ����������K��K��+���?���#M���-"�>�������$l��[��2�P/�F�Ś��,@�Fb�Z�&ϛ�2�*E5����8E�G/���Y�V����Lg
W��g�7pQ�.¾�z��m��lh���MN�ይ�}�����P���RT��<��/-��������v	P�'�?~?�	��M���
-oA��W�,�c�w<��ɤ��vCmىCN�6ly�D1���/V�T݈�������݌��N���E'vQH�Ѳ�]v�2��\Cq�e"V�;����B��P:�/l;C�G�r˜ԩ�cj�$$ �%���PT�7�w�`0���e85�DE��|/�J�d��؈��bn�L����ъ���Ia�T���l}��L�9p�C��ʰ�������FtG��4��qB��G�K�5H
�u�{�D���Ǡ�L",����x�D���*$ ���ʨ���#��)wJ�� ��y׍Xb��� K��nN�m8z6��p>C�ϰs�~�IW�����7���6=�^E��Np�p��ɿ&�}<Զ�����>���ߌ�RN�w�����xG�Qw��K��.��ǣ����ftθ������׿{�_�%5Uh~adFp�\e�DXD[tL����Ue��
"n�SɺU�o��sp��J7�U�G�A���a�#�9�[([7ʹ��	��r�qoK q�D���ɨ} 
Ve�N9�:�y5Us��B���=Ȥ��\�70�v�h�"�ɸ������	�grD��4`y�X+���5P�'.q��x�$fyCU�w{}��~�ar�D�/�"�f��x��~9��fh�*0Lh���C����B��xf�Q���BJ�g^ҔK��/�UjE
�}:�Gv{v�cu;�n�6�i	aR�%�V�)Jǖ�pwZS�0lA�>��ҵ`u�׬۾ӻ�������3ߟ����r�К�r:���Y�Ҳ��+����f)pD���A�ǐD���ꪱ�[�E`����зm�
c����V�~��[,�E	��oD`t@V���G4P3�3,����w�E
p6!uR&H=��&�<9u��\����ϓ����Ƅ	O8im�