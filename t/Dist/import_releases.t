#!/usr/bin/env perl

use lib 't/lib';
use Gitpan::perl5i;
use Gitpan::Test;

use Gitpan::Dist;

subtest "error handling" => sub {
    my $dist = Gitpan::Dist->new(
        name        => "Acme-LookOfDisapproval"
    );
    $dist->delete_repo;

    my $break_at = $dist->release_from_version(0.003);

    ok !$dist->import_releases(
        after_import => method($release) {
            die "Testing error" if $release->version == $break_at->version;
        },
        push => 0,
    );

    like $dist->config->gitpan_log_file->slurp_utf8,
      qr{^Error importing @{[$break_at->short_path]}: Testing error }ms;
    like $dist->dist_log_file->slurp_utf8,
      qr{^Testing error }ms;
};


subtest "skipping releases" => sub {
    my $dist = Gitpan::Dist->new(
        name        => "Date-Spoken-German"
    );
    $dist->delete_repo;

    # Insert a release to skip into the config.  Be sure to clear out
    # the skip release cache.  We pick this one because it is in a
    # subdirectory for extra tricks.
    $dist->config->skip->{releases}->push('CHRWIN/date-spoken-german/date-spoken-german-0.03.tar.gz');
    $dist->config->_clear_skip_releases;

    $dist->import_releases( push => 0 );

    cmp_deeply scalar $dist->git->releases->sort, [sort 
        'CHRWIN/date-spoken-german/date-spoken-german-0.02.tar.gz',
        'CHRWIN/date-spoken-german/Date-Spoken-German-0.04.tar.gz',
        'CHRWIN/date-spoken-german/Date-Spoken-German-0.05.tar.gz'
    ];
};

done_testing;

