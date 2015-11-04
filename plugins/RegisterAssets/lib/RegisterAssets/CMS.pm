package RegisterAssets::CMS;

use strict;
use warnings;
use File::Temp qw( tempdir );
use File::Basename;
use File::Spec;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Image::Size qw( imgsize );
use MT::FileMgr;
use MT::TheSchwartz;
use TheSchwartz::Job;
use MT::Serialize;

sub _registercommon_contition {
    my $app = MT->instance;
    my $user = $app->user;
    my $admin = 'can_administer_blog';
    my $perm = $user->is_superuser;
    my $blog = $app->blog;
    if ( (! $perm ) && ( $blog ) ) {
        $perm = $user->permissions( $blog->id )->$admin;
    }
    return $perm;
}

sub _app_cms_upload_common_assets {
    my $app = shift;
    if (! _registercommon_contition( $app ) ) {
        return $app->trans_error( 'Permission denied.' );
    }
    my $blog = $app->blog;
    my $blog_id = $blog->id;
    my $component = MT->component( 'RegisterAssets' );
    my $user = $app->user;
    my %param;
    if ( $app->request_method eq 'POST' ) {
        if ( $app->param( 'file' ) ) {
            my $q = $app->param;
            if ( my $file = $q->upload( 'file' ) ) {
                if (! $app->validate_magic ) {
                    return $app->trans_error( 'Permission denied.' );
                }
                my $temp = _upload( $app, 'file' );
                if ( $temp !~ /\.zip$/i ) {
                    return $app->trans_error( 'Invalid request.' );
                }
                if ( MT->config( 'RegisterAssetsByQueue' ) ) {
                    my $job = TheSchwartz::Job->new();
                    $job->funcname( 'RegisterAssets::Worker::Register' );
                    $job->uniqkey( 1 );
                    my $priority = 8;
                    $job->priority( $priority );
                    $job->coalesce( 'registerassets:' . $$ . ':' . ( time - ( time % 10 ) ) );
                    my $grabbed = time() - 120;
                    $job->run_after( $grabbed );
                    $job->grabbed_until( $grabbed );
                    my $data;
                    $data->{ blog_id } = $blog_id;
                    $data->{ author_id } = $user->id;
                    $data->{ temp } = $temp;
                    my $ser = MT::Serialize->serialize( \$data );
                    $job->arg( $ser );
                    MT::TheSchwartz->insert( $job );
                    $param{ queue_saved } = 1;
                } else {
                    my $result = _register_assets( $app, $blog, $user, $temp );
                    if (! $result ) {
                        return $app->trans_error( 'An error occurred' );
                    }
                    $param{ saved } = $result->{ saved };
                    $param{ template_count } = $result->{ template_count };
                    $param{ asset_count } = $result->{ asset_count };
                }
            }
        }
    }
    my $tmpl = File::Spec->catfile( $component->path, 'tmpl', 'import.tmpl' );
    return $app->build_page( $tmpl, \%param );
}

sub _register_assets {
    my ( $app, $blog, $user, $temp ) = @_;
    my $blog_id = $blog->id;
    my $fmgr = MT::FileMgr->new( 'Local' ) or die MT::FileMgr->errstr;
    my $tmpls = MT->config( 'RegisterTemplateExtensions' );
    my $assets = MT->config( 'RegisterAssetExtensions' );
    my $tags = MT->config( 'RegisterAssetAddTags' );
    my $build_type = MT->config( 'RegisterTemplateBuildType' );
    my @template_extensions = split( /,/, $tmpls );
    my @assets_extensions = split( /,/, $assets );
    my @assets_tags = split( /,/, $tags );
    my @tl = MT::Util::offset_time_list( time, $blog );
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d', $tl[5]+1900, $tl[4]+1, @tl[3,2,1,0];
    my $archive = Archive::Zip->new();
    unless ( $archive->read( $temp ) == AZ_OK ) {
        return undef;
    }
    my $dir = $blog->site_path;
    $dir =~ s{(?!\A)/+\z}{};
    my $asset_count = 0;
    my $template_count = 0;
    my $saved;
    my @members = $archive->members();
    for my $member ( @members ) {
        my $out = $member->fileName;
        $out =~ tr!\\!/!;
        my $blog_path = $out;
        $out = File::Spec->catfile( $dir, $out );
        my $basename = File::Basename::basename( $out );
        my $extension = '';
        if ( $basename =~ /\.([^.]+)\z/ ) {
            $extension = $1;
            $extension = lc( $extension );
        }
        if ( $extension ) {
            if ( grep( /^$extension$/, @assets_extensions ) ) {
                $archive->extractMemberWithoutPaths( $member->fileName, $out );
                next unless -f $out;
                my $class = 'file';
                require MT::Asset;
                my $asset_pkg = MT::Asset->handler_for_file( $basename );
                my $asset;
                if ( $asset_pkg eq 'MT::Asset::Image' ) {
                    $asset_pkg->isa( $asset_pkg );
                    $class = 'image';
                }
                if ( $asset_pkg eq 'MT::Asset::Audio' ) {
                    $asset_pkg->isa( $asset_pkg );
                    $class = 'audio';
                }
                if ( $asset_pkg eq 'MT::Asset::Video' ) {
                    $asset_pkg->isa( $asset_pkg );
                    $class = 'video';
                }
                $asset = $asset_pkg->get_by_key( { blog_id => $blog_id,
                         file_path => '%r/' . $blog_path } );
                my $original = $asset->clone_all();
                my $mime_type = _mime_type( $extension );
                $asset->url( '%r/' . $blog_path );
                $asset->label( $basename );
                $asset->file_name( $basename );
                $asset->mime_type( $mime_type );
                $asset->file_ext( $extension );
                $asset->class( $class );
                if (! $asset->created_by ) {
                    $asset->created_by( $user->id );
                }
                $asset->modified_by( $user->id );
                if ( $class eq 'image' ) {
                    my ( $w, $h, $id ) = imgsize( $out );
                    $asset->image_width( $w );
                    $asset->image_height( $h );
                }
                if (! $asset->id ) {
                    $asset->save or die $asset->errstr;
                }
                $asset->set_tags( @assets_tags );
                if ( ( ref $app ) eq 'MT::App::CMS' ) {
                    $app->run_callbacks( 'cms_pre_save.asset', $app, $asset, $original )
                      || return $app->errtrans( "Saving [_1] failed: [_2]", 'asset',
                        $app->errstr );
                    }
                $asset->save or die $asset->errstr;
                $asset_count++;
                $saved = 1;
                if ( ( ref $app ) eq 'MT::App::CMS' ) {
                    $app->run_callbacks( 'cms_post_save.asset', $app, $asset, $original );
                } else {
                    my $message = MT->translate( 'File \'[_1]\' uploaded by \'[_2]\'', $basename, $user->name );
                    MT->log(
                        {   message  => $message,
                            class    => 'asset',
                            category => 'new',
                            blog_id  => $blog_id,
                            author_id => $user->id,
                            level    => MT::Log::INFO()
                        }
                    );
                }
            } elsif ( grep( /^$extension$/, @template_extensions ) ) {
                $archive->extractMemberWithoutPaths( $member->fileName, $out );
                next unless -f $out;
                my $template = MT->model( 'template' )->get_by_key( { blog_id => $blog_id,
                                                                      outfile => $blog_path,
                                                                      type => 'index',
                                                                    } );
                my $is_new;
                if (! $template->id ) {
                    $is_new = 1;
                }
                my $original = $template->clone_all;
                $template->build_type( $build_type );
                if ( $build_type == 1 ) {
                    $template->rebuild_me( 1 );
                }
                my $identifier = $blog_path;
                $identifier =~ s!/!_!g;
                $identifier =~ s!\.!_!g;
                $template->identifier( $identifier );
                $template->name( $blog_path );
                my $data = $fmgr->get_data( $out );
                $template->text( $data );
                $template->modified_on( $ts );
                $template->modified_by( $user->id );
                if ( ( ref $app ) eq 'MT::App::CMS' ) {
                    $app->run_callbacks( 'cms_pre_save.template', $app, $template, $original )
                      || return $app->errtrans( "Saving [_1] failed: [_2]", 'template',
                        $app->errstr );
                }
                $template->save or die $template->errstr;
                if ( $is_new ) {
                    my $message = MT->translate( 'Template \'[_1]\' (ID:[_2]) created by \'[_3]\'', $template->name, $template->id, $user->name );
                    MT->log(
                        {   message  => $message,
                            class    => 'template',
                            category => 'edit',
                            blog_id  => $blog_id,
                            author_id => $user->id,
                            level    => MT::Log::INFO()
                        }
                    );
                }
                my $message = MT->translate( '\'[_1]\' edited the template \'[_2]\' in the blog \'[_3]\'', $user->name, $template->name, $blog->name );
                MT->log(
                    {   message  => $message,
                        class    => 'template',
                        category => 'edit',
                        blog_id  => $blog_id,
                        author_id => $user->id,
                        level    => MT::Log::INFO()
                    }
                );
                $template_count++;
                $saved = 1;
                __mt_presave_obj( $app, $template, $original, $user, $blog );
                if ( ( ref $app ) eq 'MT::App::CMS' ) {
                    $app->run_callbacks( 'cms_post_save.template', $app, $template, $original );
                }
            }
        }
    }
    my $result = { saved => $saved,
                   template_count => $template_count,
                   asset_count => $asset_count };
    return $result;
}

sub __mt_presave_obj {
    my ( $app, $obj, $orig, $user, $blog ) = @_;
    $obj->gather_changed_cols( $orig, $app );
    return 1 unless exists $obj->{ changed_revisioned_cols };
    my $changed_cols = $obj->{ changed_revisioned_cols };
    if ( ( ref $app ) ne 'MT::App::CMS' ) {
        if ( scalar @$changed_cols ) {
            my $col = 'max_revisions_' . $obj->datasource;
            my $max = $blog->$col;
            $obj->handle_max_revisions( $max );
            my $revision = $obj->save_revision();
            my $num = $revision + 0;
            my $datasource = $obj->datasource;
            my $rev_class  = MT->model( $datasource . ':revision' );
            my $terms = { $datasource . '_id' => $obj->id,
                          rev_number => $num };
            my $rev_obj = $rev_class->load( $terms );
            $rev_obj->created_by( $user->id );
            $rev_obj->save or die $rev_obj->errstr;
            $obj->current_revision( $revision );
            $obj->update or return $obj->error( $obj->errstr );
            if ( $obj->has_meta( 'revision' ) ) {
                $obj->revision( $revision );
                $obj->{ __meta }->set_primary_keys( $obj );
                $obj->{ __meta }->save;
            }
        }
    }
    return 1;
}

sub _mime_type {
    my $extension = shift;
    my %mime_type = (
        'css'   => 'text/css',
        'html'  => 'text/html',
        'mtml'  => 'text/html',
        'htm'   => 'text/html',
        'txt'   => 'text/plain',
        'xml'   => 'application/xml',
        'atom'  => 'application/atom+xml',
        'rss'   => 'application/rss+xml',
        'rdf'   => 'application/rdf+xml',
        'mpeg'  => 'video/mpeg',
        'mpg'   => 'video/mpeg',
        'mpe'   => 'video/mpeg',
        'avi'   => 'video/x-msvideo',
        'mov'   => 'video/quicktime',
        'js'    => 'application/javascript',
        'json'  => 'application/json',
        'swf'   => 'application/x-shockwave-flash',
        'mp3'   => 'audio/mpeg',
        'bmp'   => 'image/x-ms-bmp',
        'gif'   => 'image/gif',
        'jpeg'  => 'image/jpeg',
        'jpg'   => 'image/jpeg',
        'jpe'   => 'image/jpeg',
        'png'   => 'image/png',
        'ico'   => 'image/vnd.microsoft.icon',
    );
    my $type = $mime_type{ $extension };
    $type = 'text/plain' unless $type;
    return $type;
}

sub _upload {
    my ( $app, $name ) = @_;
    my $tempdir = $app->config( 'TempDir' );
    my $dir = tempdir( DIR => $tempdir );
    my $errors = {};
    my $limit = $app->config( 'CGIMaxUpload' ) || 20480000;
    my $fmgr = MT::FileMgr->new( 'Local' ) or die MT::FileMgr->errstr;
    my $q = $app->param;
    my $file = $q->upload( $name );
    my $size = ( -s $file );
    if ( $limit < $size ) {
        $errors->{ error } = MT->trans_error( 'The file you uploaded is too large.' );
        return $errors;
    }
    my $out = File::Spec->catfile( $dir, File::Basename::basename( $file ) );
    $dir =~ s!/$!! unless $dir eq '/';
    unless ( $fmgr->exists( $dir ) ) {
        $fmgr->mkpath( $dir ) or return { error => MT->trans_error( "Error making path '[_1]': [_2]",
                                $out, $fmgr->errstr ) };
    }
    my $temp  = "$out.new";
    my $umask = $app->config( 'UploadUmask' );
    my $old   = umask( oct $umask );
    open( my $fh, ">$temp" ) or die "Can't open $temp!";
    binmode( $fh );
    while ( read( $file, my $buffer, 1024 ) ) {
        print $fh $buffer;
    }
    close( $fh );
    $fmgr->rename( $temp, $out );
    umask( $old );
    return $out;
}

1;