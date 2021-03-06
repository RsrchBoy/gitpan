package Gitpan::Release;

use Gitpan::perl5i;
use Gitpan::OO;
use Gitpan::Types;

with
  'Gitpan::Role::HasBackpanIndex',
  'Gitpan::Role::HasConfig',
  'Gitpan::Role::HasCPANAuthors',
  'Gitpan::Role::HasUA';

haz distname =>
  is            => 'ro',
  isa           => DistName,
  default       => method {
      return $self->backpan_release->dist->name;
  };

with 'Gitpan::Role::CanDistLog';

haz version =>
  is            => 'ro',
  isa           => Str,
  default       => method {
      return $self->backpan_release->version;
  };

haz gitpan_version =>
  is            => 'ro',
  isa           => Str,
  lazy          => 1,
  default       => method {
      my $version = $self->version;
      $version =~ s{^v}{};

      return $version;
  };


require BackPAN::Index::Release;
# Fuck Type short_path() into BackPAN::Index::Release.
*BackPAN::Index::Release::short_path = method {
    my $path = $self->path;
    $path =~ s{^authors/id/\w/\w{2}/}{};
    return $path;
};


haz backpan_release =>
  is            => 'ro',
  isa           => InstanceOf['BackPAN::Index::Release'],
  lazy          => 1,
  handles       => [qw(
      cpanid
      date
      distvname
      filename
      maturity
      short_path
  )],
  default       => method {
      return $self->backpan_index
                  ->releases($self->distname)
                  ->single({ version => $self->version });
  };

haz url =>
  is            => 'ro',
  isa           => URI,
  lazy          => 1,
  default       => method {
      my $url = $self->config->backpan_url->clone;
      $url->append_path($self->path);

      return $url;
  };

haz backpan_file     =>
  is            => 'ro',
  isa           => InstanceOf['BackPAN::Index::File'],
  lazy          => 1,
  handles       => [qw(
      path
      size
  )],
  default       => method {
      $self->backpan_release->path;
  };

haz author =>
  is            => 'ro',
  isa           => InstanceOf['Gitpan::CPAN::Author'],
  lazy          => 1,
  default       => method {
      return $self->cpan_authors->author($self->cpanid);
  };

haz work_dir =>
  is            => 'ro',
  isa           => AbsPath,
  lazy          => 1,
  default       => method {
      require Path::Tiny;
      return Path::Tiny->tempdir;
  };

haz archive_file =>
  is            => 'rw',
  isa           => AbsPath,
  lazy          => 1,
  default       => method {
      return $self->work_dir->child( $self->filename );
  };

haz extract_dir =>
  isa           => AbsPath,
  clearer       => "_clear_extract_dir";

haz github_file_size_limit =>
  isa           => Int,
  default       => 100 * 1024 * 1024;

method BUILDARGS($class: %args) {
    croak "distname & version or backpan_release required"
      unless ($args{distname} && defined $args{version}) || $args{backpan_release};

    return \%args;
}


method get(
    Bool :$check_size           = 1,
    Bool :$get_file_urls        = 0
) {
    my $url = $self->url;

    $self->dist_log( "Getting $url" );

    my $res;
    if( !$get_file_urls && $url->scheme eq 'file' ) {
        my $path = $url->path;
        croak "Could not find $path" unless -e $path;
        $self->archive_file($path);
        $res = HTTP::Response->new( 200, "file URL not copied" );
    }
    else {
        $res = $self->ua->get(
            $url,
            ":content_file" => $self->archive_file.""
        );
    }

    croak "Get from $url was not successful: ".$res->status_line
      unless $res->is_success;

    my $archive_size = -s $self->archive_file;
    croak "File not fully retrieved, got $archive_size, expected @{[$self->size]}"
      if $check_size && -s $self->archive_file != $self->size;

    return $res;
}

method extract {
    my $archive = $self->archive_file;
    my $dir     = $self->work_dir;

    $self->dist_log( "Extracting $archive to $dir" );

    croak "$archive does not exist, did you get it?" unless -e $archive;

    require Archive::Extract;
    local $Archive::Extract::PREFER_BIN = 1;
    my $ae = Archive::Extract->new( archive => $archive );
    $ae->extract( to => $dir ) or
      croak "Couldn't extract $archive to $dir: ". $ae->error;

    croak "Archive is empty"                    if !$ae->extract_path;
    croak "Extraction directory does not exist" if !-e $ae->extract_path;

    $self->extract_dir( $ae->extract_path );

    $self->fix_permissions;

    $self->fix_big_files;

    $self->fix_extract_dir($ae);

    return $self->extract_dir;
}

# Check for tarballs which unpack into cwd.  Archive::Extract does not
# eliminate the top level directory for us.
method fix_extract_dir( Archive::Extract $ae ) {
    my $files = $ae->files;

    return unless $files->first(qr{^\./.+$});

    my @children = $self->extract_dir->children;
    croak "Too many files in the extraction dir to fix it: @children" if @children > 1;

    my $child = $children[0];
    CORE::system( "mv $child/* ".$self->extract_dir ) == 0 ||
        croak "Could not move $child/* to ".$self->extract_dir;

    rmdir $child;

    return 1;
}

# Make sure the archive files are readable and the directories are traversable.
method fix_permissions {
    return unless -d $self->extract_dir;

    $self->extract_dir->chmod("u+rx");

    require File::Find;
    File::Find::find(sub {
        -d $_ ? $_->path->chmod("u+rx") :
        -f $_ ? $_->path->chmod("u+r")  :
                1;
    }, $self->extract_dir);

    return;
}

method fix_big_files() {
    return unless -d $self->extract_dir;

    my $limit = $self->github_file_size_limit;

    require File::Find;
    File::Find::find(sub {
        return if !-f $_;
        return if -s $_ < $limit;
        $self->truncate_file($File::Find::name);
    }, $self->extract_dir);
}

method truncate_file( $file ) {
    my $limit = ($self->github_file_size_limit / 1024 / 1024)->round;
    my $size  = ((-s $file) / 1024 / 1024)->round;
    my $url   = "http://backpan.cpan.org/".$self->path;

    $file->path->spew_utf8(<<"END");
Sorry, this file has been truncated by Gitpan.
It was $size megs which exceeds Github's limit of $limit megs per file.
You can get the file from the original archive at $url
END

    return;
}

method move(
    Path::Tiny $to,
    Bool :$clean_for_import = 1
) {
    croak "$to is not a directory" if !-d $to;

    $self->extract if !$self->extract_dir;
    my $from = $self->extract_dir;

    $self->clean_extraction_for_import if $clean_for_import;

    $self->dist_log( "Moving from $from to $to" );

    # Work around autodie failure.
    # "Internal error in Fatal/autodie.  Leak-guard failure"
    CORE::system( "mv \Q$from\E/* \Q$to\E" ) && croak "mv failed: $!";

    # Have to re-extract
    $self->_clear_extract_dir;

    return;
}


method clean_extraction_for_import() {
    my $dir = $self->extract_dir;

    # A .git directory in the tarball will interfere with
    # our own git repository.
    my $git_dir = $dir->child(".git");
    if( -e $git_dir ) {
        $self->dist_log("Removing .git directory from the archive.");
        $git_dir->remove_tree({ safe => 0 });
    }

    return;
}
