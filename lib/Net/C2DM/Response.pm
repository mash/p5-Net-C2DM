package Net::C2DM::Response;
use Any::Moose;

has raw                 => ( is => 'rw', isa => 'HTTP::Response', required => 1 );
has id                  => ( is => 'rw', isa => 'Str' );
has is_success          => ( is => 'rw', isa => 'Bool' );
has error_code          => ( is => 'rw', isa => 'Str' );
has updated_client_auth => ( is => 'rw', isa => 'Str' );

no Any::Moose;

sub BUILD {
    my ($self, $args) = @_;

    if ( my $update = $self->raw->header('Update-Client-Auth') ) {
        # untested
        $self->updated_client_auth( $update );
    }

    my $content = $self->raw->content;
    if ( $content =~ m!id=(.*)$! ) {
        $self->id( $1 );
        $self->is_success( 1 );
    }
    elsif ( $content =~ m!Error=(.*)$! ) {

        warn "error_code: $1";

        $self->error_code( $1 );
        $self->is_success( 0 );
    }
    else {
        # changed api spec?
        $self->error_code( 'ResponseParseError' );
        $self->is_success( 0 );
    }
}

__PACKAGE__->meta->make_immutable;
