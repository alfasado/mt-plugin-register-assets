package RegisterAssets::Worker::Register;

use strict;
use base qw( TheSchwartz::Worker );
use MT::Serialize;

use TheSchwartz::Job;
sub keep_exit_status_for {1}
sub grab_for             {60}
sub max_retries          {10}
sub retry_delay          {1}

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $component = MT->component( 'RegisterAssets' );
    my @jobs;
    push @jobs, $job;
    if ( my $key = $job->coalesce ) {
        while ( my $job = MT::TheSchwartz->instance->find_job_with_coalescing_value( $class, $key ) ) {
            push @jobs, $job;
        }
    }
    my $app = MT->instance();
    foreach $job ( @jobs ) {
        my $arg = $job->arg;
        my $data = MT::Serialize->unserialize( $arg );
        my $blog_id = $$data->{ blog_id };
        my $author_id = $$data->{ author_id };
        my $blog = MT->model( 'blog' )->load( $blog_id );
        my $user = MT->model( 'author' )->load( $author_id );
        my $temp = $$data->{ temp };
        require RegisterAssets::CMS;
        my $result = RegisterAssets::CMS::_register_assets( $app, $blog, $user, $temp );
        if (! $result ) {
            return $job->failed();
        }
        return $job->completed();
    }
    return 1;
}

1;
