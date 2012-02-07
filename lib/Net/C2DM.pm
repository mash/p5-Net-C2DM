package Net::C2DM;
use Any::Moose;
use LWP::UserAgent;
use Net::C2DM::Response;
use Log::Minimal;

our $VERSION = 0.01;

has email             => ( is => 'rw', isa => 'Str', );
has passwd            => ( is => 'rw', isa => 'Str', );
has cache             => ( is => 'rw', );
has cache_key         => ( is => 'rw', isa => 'Str', lazy => 1, default => '__net_c2dm_clientlogin_token' );
has cache_expires     => ( is => 'rw', isa => 'Int', lazy => 1, default => sub { 60 * 60 * 24 * 7; } );
has clientlogin_token => ( is => 'rw', isa => 'Str', );
has ua                => ( is => 'rw', lazy => 1,
                           default => sub {
                               my ($self) = @_;
                               return LWP::UserAgent->new(
                                   timeout  => 3,
                                   agent    => join( '/', (__PACKAGE__, $VERSION) ),
                                   ssl_opts => { verify_hostname => 0 }, # not so nice
                               );
                           });
has clientlogin_endpoint => ( is => 'rw', isa => 'Str', lazy => 1,
                              default => 'https://www.google.com/accounts/ClientLogin' );
has clientlogin_source   => ( is => 'rw', isa => 'Str', lazy => 1,
                              default => sub {
                                  return join('-', (__PACKAGE__, $VERSION));
                              } );
has c2dm_endpoint        => ( is => 'rw', isa => 'Str', lazy => 1,
                              default => 'https://android.apis.google.com/c2dm/send' );

no Any::Moose;

sub fresh_clientlogin_token {
    my ($self) = @_;
    my $ret;

    if ( $self->cache && $self->cache->can('get') ) {
        $ret = $self->cache->get( $self->cache_key );
    }
    unless ($ret) {
        if ( $self->email && $self->passwd ) {
            $ret = $self->fetch_clientlogin_token;
        }
    }
    unless ( $ret ) {
        die 'provide email and password, or a cache filled with a default client login token';
    }
    return $ret;
}

sub fetch_clientlogin_token {
    my ($self) = @_;

    my $res = $self->ua->post( $self->clientlogin_endpoint, {
        Email       => $self->email,
        Passwd      => $self->passwd,
        accountType => 'GOOGLE',
        source      => $self->clientlogin_source,
        service     => 'ac2dm',
    });

    infof 'fetched clientlogin token: '.$res->content;

    if ( $res->is_success ) {
        my %tokens = split( /[=\n]/, $res->content );
        my $ret    = $tokens{ Auth };

        if ( $self->cache && $self->cache->can('set') ) {
            $self->cache->set( $self->cache_key => $ret, $self->cache_expires );
        }

        return $ret;
    }
    warnf 'clientlogin failed: '.$res->status_line . ' ' . $res->content;
    return;
}

sub c2dm_params {
    my ($self, $registration_id, $payload) = @_;

    my $collapse_key;

    # add "data." prefix for all keys
    # todo: limit message size?
    my %data;
    if ( defined( $payload->{data} ) && (ref($payload->{data}) eq 'HASH') ) {
        my $_data = delete $payload->{data};
        for my $key (keys %{ $_data }) {
            $data{ "data.$key" } = $_data->{ $key };
        }
        $collapse_key = $self->clientlogin_source . '-' . join('-',sort keys %$_data);
    }

    return {
        registration_id => $registration_id,
        collapse_key    => $collapse_key,
        %$payload,
        %data,
    };
}

sub send {
    my ($self, $registration_id, $payload) = @_;

    # token can be either preset(initially and statically) or fresh(fetched from clientlogin auth api or cache)
    my $token = $self->clientlogin_token || $self->fresh_clientlogin_token;

    my $post_params = $self->c2dm_params( $registration_id, $payload );

    my $raw_res = $self->ua->post(
        $self->c2dm_endpoint,
        $post_params,
        Authorization => "GoogleLogin auth=$token"
    );
    my $res = Net::C2DM::Response->new( raw => $raw_res );

    if ( $res->is_success &&
         $self->cache     &&
         $self->cache->can('set') &&
         (my $next_auth = $res->updated_client_auth) ) {
        $self->cache->set( $self->cache_key => $next_auth, $self->cache_expires );
    }
    elsif ( ($raw_res->code == 401) &&
                $self->cache &&
                    $self->cache->can('delete') ) {
        $self->cache->delete( $self->cache_key );
    }

    # todo: do retry or exponential back off?

    return $res;
}

__PACKAGE__->meta->make_immutable;
