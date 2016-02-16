#!perl

# Copyright (c) 2002 Mattia Barbon.
# Copyright (c) 2002 Audrey Tang.
# This package is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Basename;
use File::Glob;
use File::Spec::Functions ':ALL';
use Cwd 'realpath';
use Getopt::Long;
use IO::Compress::Gzip qw(gzip $GzipError);
use Config;

my $chunk_size = 32768;
my $compress = 0;

GetOptions(
    "c|chunk-size=i"    => \$chunk_size,
    "z|compress"        => \$compress)
    && @ARGV == 1
        or die "Usage: $0 [-c CHUNK][-z] par > file.c\n";
my ($par) = @ARGV;

sub is_system_lib;

my $dlls;
for ($^O)
{
    # sane platforms: use "ldd"
    if (/linux|solaris|freebsd|openbsd/i) 
    {
        print STDERR qq[# using "ldd" to find shared libraries needed by $par\n];
        *is_system_lib = sub { shift =~ m{^(?:/usr)?/lib(?:32|64)?/} };

        $dlls = ldd($par); 
        last;
    }

    # Max OS X: use "otool -L"
    if (/darwin/i && (qx(otool --version), $? == 0)) 
    {
        print STDERR qq[# using "otool -L" to find shared libraries needed by $par\n];
        *is_system_lib = sub { shift =~ m{^/usr/lib|^/System/Library/} };

        $dlls = otool($par); 
        last;
    }

    # Windows with Mingw toolchain: use "objdump" recursively
    if (/mswin32/i && (qx(objdump --version), $? == 0))
    {
        print STDERR qq[# using "objdump" recusrively to find DLLs needed by $par\n];
        my $system_root = realpath($ENV{SystemRoot});
        *is_system_lib = sub { realpath(shift) =~ m{^\Q$system_root\E/}i };

        $dlls = objdump($par);
        last;
    }

    # fall back to guessing game
    print STDERR qq[# fall back to guessing what DLLs are needed by $par\n];
    $dlls = fallback($par);
}


my $n = 0;
my @embedded_files = {          # par is always the first embedded file
    name   => basename($par),
    size   => -s $par,
    chunks => file2c("file$n", $par),
};
$n++;

while (my ($name, $file) = each %$dlls)
{
    push @embedded_files, {
        name   => $name,
        size   => -s $file,
        chunks => file2c("file$n", $file),
    };
    $n++;
}

print "static embedded_file_t embedded_files[] = {\n";
print "  { \"$_->{name}\", $_->{size}, $_->{chunks} },\n" foreach @embedded_files;
print "  { NULL, 0, NULL }\n};";
           
exit 0;


sub ldd
{
    my ($file) = @_;

    my $out = qx(ldd $file);
    die qq["ldd $file" failed\n] unless $? == 0;

    my %dlls = $out =~ /^ \s* (\S+) \s* => \s* (\S+) /gmx;

    # weed out system libraries (except the perl shared library)
    while (my ($name, $path) = each %dlls)
    {
        delete $dlls{$name} unless -r $path;    # huh?

        next if $name =~ /^libperl/;
        delete $dlls{$name} if is_system_lib($path);
    }

    return \%dlls;
}

# NOTE: "otool -L" is NOT recursive, i.e. it's the equivalent
# of "objdump -ax" or "readelf -d" on Linux, but NOT "ldd".
# So perhaps a recursive method like the one for objdump below is in order.
sub otool
{
    my ($file) = @_;

    my $out = qx(otool -L $file);
    die qq["otool -L $file" failed\n] unless $? == 0;

    return { map { basename($_) => $_ }
                 grep { basename($_) =~ /^libperl/ || !is_system_lib($_) }
                      $out =~ /^ \s+ (\S+) /gmx };
}

sub objdump
{
    my ($path) = @_;

    my %dlls;;
    _objdump($path, "", { lc realpath($path) => 1 }, \%dlls);

    # weed out system libraries
    while (my ($name, $path) = each %dlls)
    {
        delete $dlls{$name} if is_system_lib($path);
    }
        
    return \%dlls;
}

sub _objdump
{
    my ($path, $level, $seen, $dlls) = @_;

    my $out = qx(objdump -ax "$path");
    die "objdump failed: $!\n" unless $? == 0;
    
    foreach my $dll ($out =~ /^\s*DLL Name:\s*(\S+)/gm)
    {
        next if $dlls->{$dll};

        my $path = _find_dll($dll) or next;
        $dlls->{$dll} = $path;

        next if $seen->{$path};
        _objdump($path, "$level  ", $seen, $dlls) 
            unless is_system_lib($path);
        $seen->{lc $path} = 1;
    }
}

sub _find_dll
{
    my ($name) = @_;

    foreach (path())
    {
        my $path = catfile($_, $name);
        return realpath($path) if -r $path;
    }
    return;
}

# If on Windows and Perl was built with GCC 4.x, then libperl*.dll
# may depend on some libgcc_*.dll (e.g. Strawberry Perl 5.12).
# This libgcc_*.dll has to be included into with any packed executable 
# in the same way as libperl*.dll itself, otherwise a packed executable
# won't run when libgcc_*.dll isn't installed.
# The same holds for libstdc++*.dll (e.g. Strawberry Perl 5.16).

sub fallback
{
    my ($file) = @_;

    my @libs;
    if ($^O eq 'MSWin32'
        and defined $Config{gccversion}             # gcc version >= 4.x was used
        and $Config{gccversion} =~ m{\A(\d+)}ms && $1 >= 4) 
    {
        push @libs, _find_dll_glob("libgcc_*.$Config{so}"),
                    _find_dll_glob("libwinpthread*.$Config{so}");
    }

    my $ld = $Config{ld} || (($^O eq 'MSWin32') ? 'link.exe' : $Config{cc});
    $ld = $Config{cc} if ($^O =~ /^(?:dec_osf|aix|hpux)$/);
    if ($ld =~ /(\b|-)g\+\+(-.*)?(\.exe)?$/)        # g++ was used to link
    {
        push @libs, _find_dll_glob("libstdc++*.$Config{so}");
    }

    return { map { basename($_) => $_ } grep { defined } @libs };
}

sub _find_dll_glob
{
    my ($dll_glob) = @_;

    # look for $dll_glob
    # - in the same directory as the perl executable itself
    # - in the same directory as gcc (only useful if it's an absolute path)
    # - in PATH
    my ($dll_path) = map { File::Glob::bsd_glob(catfile($_, $dll_glob)) }
                         dirname($^X),
                         dirname($Config{cc}),
                         path();
    return $dll_path;
}


sub file2c
{
    my ($prefix, $path) = @_;

    my $bin = do           # a scalar reference
    {
        open my $in, "<", $path or die "open input file '$path': $!";
        binmode $in;
        local $/ = undef;
        my $slurp = <$in>;
        close $in;
        \$slurp;
    };


    if ($compress)
    {
        my $gzipped;
        my $status = gzip($bin, \$gzipped)
            or die "gzip failed: $GzipError\n";
        $bin = \$gzipped;
    }

    my $len = length $$bin;
    my $chunk_count = int(( $len + $chunk_size - 1 ) / $chunk_size);

    my @chunks;
    for (my $offset = 0, my $i = 0; $offset <= $len; $offset += $chunk_size, $i++)
    {
        my $name = "${prefix}_${i}";
        push @chunks, { 
               name => $name,
               len  => print_chunk(substr($$bin, $offset, $chunk_size), $name),
        };
    } 

    print "static chunk_t ${prefix}[] = {\n";
    print "  { $_->{len}, $_->{name} },\n" foreach @chunks;
    print "  { 0, NULL } };\n\n";

    return $prefix;
}

sub print_chunk 
{
    my ($chunk, $name) = @_;

    my $len = length($chunk);
    print qq[static unsigned char ${name}[] =];
    my $i = 0;
    do
    {
        print qq[\n"];
        while ($i < $len)
        {
            printf "\\x%02x", ord(substr($chunk, $i++, 1));
            last if $i % 16 == 0;
        }
        print qq["];
    } while ($i < $len);
    print ";\n";
    return $len;
}

# local variables:
# mode: cperl
# end: