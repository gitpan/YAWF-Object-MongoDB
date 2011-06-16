package YAWF::Object::MongoDB;

use 5.006;
use warnings;
use strict;
no strict 'refs';

use MongoDB;
use MongoDB::OID;

use YAWF::Object::MongoDB::Data;

=head1 NAME

YAWF::Object::MongoDB - Object of a MongoDB document

=head1 VERSION

Version 0.01

=head1 NOTICE

This module has been written to be compatible to the YAWF::Object methods, but
it can be used standalone without YAWF even installed.

=cut

our $VERSION = '0.01';

our $DEFAULT_SERVER     = '';          # Use localhost with default port
our $DEFAULT_DATABASE   = 'default';
our $DEFAULT_COLLECTION = 'default';
our $DEBUG              = $ENV{YAWF_MONGODB_TRACE} || 0;

my %SERVER;
my %DATABASE;
my %COLLECTION;
my %SERVER_CACHE;
my %DATABASE_CACHE;
my %COLLECTION_CACHE;

eval { require YAWF; };
my $YAWF = $@ ? 0 : 1;

=head1 SYNOPSIS

Abstraction layer for a MongoDB database

This module is used as @ISA or use base parent for object modules of your
project, it won't work standalone.

    package My::Project::ObjectClass;

    # Typical use
    use YAWF::Object::MongoDB (collection => 'my_collection',
                               keys       => ['foo', 'bar'],
                               );

    my @ISA = ('YAWF::Object::MongoDB');
    
    1;

Within your script:

    use My::Project::ObjectClass;
    
    my $object = My::Project::ObjectClass->new();
    my $object = My::Project::ObjectClass->list();
    [...]

Other definition options (you'll always need @ISA/use base in addition):

    # Custom database info
    use YAWF::Object::MongoDB (server     => 'localhost:28017',
                               database   => 'my_db',
                               collection => 'my_collection',
                               keys       => ['foo', 'bar'],
                               );

    # Complex key definition with sub-objects
    use YAWF::Object::MongoDB (collection => 'my_collection',
                               keys       => {
                                        foo => 1,
                                        bar => {
                                            baz  => 1, # Enables $object->bar->baz($new_value);
                                            true => sub { return 1; },
                                            }
                                   },
                               );

    # Provide server, database and collection at runtime:
    use YAWF::Object::MongoDB (keys       => ['foo', 'bar']);
    sub SERVER { return 'localhost:28017'; }    # Called at runtime during the first
    sub DATABASE { return 'my_database'; }      # access to the database, may even        
    sub COLLECTION { return 'my_collection'; }  # change during runtime.

    # MongoDB data my also be defined in yawf.yml:
    mongodb:
        server: localhost:28017
        database: My_Database
        collection: 1_collection_for_everything
 
    # Bad way (may harm other projects running in the same mod_perl):
    $YAWF::Object::MongoDB::DEFAULT_SERVER = 'my.custom.server:99999';

Server, database and collection can be set at different places, priority order is:
 * sub in class
 * value given at "use"-time
 * YAWF config value
 * $DEFAULT_* values in YAWF::Object::MongoDB

=head1 CLASS METHODS

=head2 list

  my @objects = YAWF::Object::MongoDB->list(); # Get all items of a table (could be big!)
  my @objects = YAWF::Object::MongoDB->list({ foo => bar }); # Search for a list of items

=cut

sub list {
    my $class = shift;

    my $filter     = shift || {};
    my $attributes = shift || {};

    # Quick way without attributes
    return
      map { bless { _document => $_ }, $class; }
      $class->_collection->find($filter)->all
      unless scalar( %{$attributes} );

    # Convert attributes and use MongoDB cursor
    my %mongo_attr;

    if ( $attributes->{rows} ) {
        $mongo_attr{limit} = $attributes->{rows};
        delete $attributes->{rows};
    }

    if ( $attributes->{page} ) {
        if ( $mongo_attr{limit} ) {
            $mongo_attr{skip} =
              $mongo_attr{limit} * ( $attributes->{page} - 1 );
            delete $attributes->{page};
        } else {
            warn $class
              . ' attribute page specified but rows is missing, page ignored';
        }
    }

    if ( $attributes->{order_by} ) {
        $mongo_attr{sort_by} =
          [ $class->_resolv_sort( $attributes->{order_by} ) ];
        delete $attributes->{order_by};
    }

    return
      map { bless { _document => $_ }, $class; }
      $class->_collection->query( $filter, $attributes )->all;

}

=pod

=head2 count

  my $count = YAWF::Object::MongoDB->count(); # Get the number of items in this table
  my $count = YAWF::Object::MongoDB->count({ foo => bar }); # Get the number of items for this search

=cut

sub count {
    my $class = shift;

    my $filter = shift || {};

    return $class->_collection->find($filter)->count;

}

=head1 METHODS

=head2 new

  my $object = YAWF::Object::MongoDB->new(); # New item
  my $object = YAWF::Object::MongoDB->new($id); # Get item by primary key
  my $object = YAWF::Object::MongoDB->new(foo => 'bar'); # Search item (returns the first)
  my $object = YAWF::Object::MongoDB->new(foo => 'bar',
                                          baz => 'foo'); # Search item (returns the first)

The C<new> constructor lets you create a new B<YAWF::Object::MongoDB> object.

The first syntax creates a new, empty item while the others return an existing
item from the database or undef if nothing was found.

=cut

sub new {
    my $class = shift;

    warn $class . ' new with (' . join( ',', @_ ) . ")\n" if $DEBUG;
    my $document;
    if ( $#_ > 0 ) {
        $document = $class->_collection->find_one( {@_} );
        return unless $document;
    } elsif ( ( $#_ == 0 ) and defined( $_[0] ) and ( $_[0] ne '' ) ) {
        die 'id ' . $_[0] . ' is a ' . ref( $_[0] ) if ref( $_[0] );
        $document = $class->_collection->find_one(
            { _id => MongoDB::OID->new( value => $_[0] ) } );
        return unless $document;
    }

    return bless { _document => $document }, $class;
}

=head2 get_column

  $object->get_column($key);

Returns the current value of any key, no matter if it has been predefined.

=cut

sub get_column {
    my $self = shift;
    my $key  = shift;

    return $self->{_changes}->{$key} if defined( $self->{_changes}->{$key} );
    return $self->{_document}->{$key};
}

=head2 set_column

  $object->set_column($key,$value);

Assign a new value to a key, no matter if it has been predefined.
Returns the new value.

=cut

sub set_column {
    my $self  = shift;
    my $key   = shift;
    my $value = shift;

    if (   ( ( !defined($value) ) and defined( $self->{_document}->{$key} ) )
        or ( defined($value) and ( !defined( $self->{_document}->{$key} ) ) )
        or ( defined($value) and ( $value ne $self->{_document}->{$key} ) ) )
    {
        $self->{_changes}->{$key} = $value;
    }

    return $value;
}

=head2 getset_column

  $object->getset_column($key);
  $object->getset_column($key,$value);

Returns the current value of any key, no matter if it has been predefined.

Sets the current values (and returns the new one) if a value (including undef) is given
as the second argument.

=cut

sub getset_column {
    my $self = shift;
    my $key  = shift;

    return $self->set_column( $key, @_ ) if $#_ > -1;
    return $self->get_column($key);
}

=head2 changed

  $object->changed($key);

Flags column $key as changed (will be flushed on next ->flush call).

=cut

sub changed {
    my $self  = shift;
    my $key   = shift;

    return if exists($self->{_changes}->{$key});

    $self->{_changes}->{$key} = $self->get_column($key);
}

=head2 id

  $object->id;

Returns the unique document id.

=cut

sub id {
    my $self = shift;

    return unless $self->get_column('_id');
    return $self->get_column('_id')->value;
}

=head2 flush

  $object->flush;

Write a YAWF object into the database with automatic selection of insert or update
depending on the objects state (new or existing).

Changes the variable used to call the method to the new object and also returns the
new object.

=cut

sub flush {
    my $self = shift;

    if ( ( !$self->{_document}->{_id} )
        and scalar( keys( %{ $self->{_changes} } ) ) )
    {
        warn $self->_unify . " New document\n" if $DEBUG;

        # New document
        my $id =
          $self->_collection->insert( $self->{_changes} );    # Insert into DB
        if ($id) {    # Insert successful
            $self->{_document} = $self->{_changes};   # Copy changes to document
            $self->{_document}->{_id} = $id;    # Store id in local document
            delete $self->{_changes};           # All changes are flushed
        } else {
            warn 'Error inserting a ' . $self->_unify . ' document';
            return undef;
        }
    } elsif ( scalar( keys( %{ $self->{_changes} } ) ) ) {
        warn $self->_unify
          . " Update document "
          . $self->id
          . " with "
          . join( ', ', keys( %{ $self->{_changes} } ) ) . "\n"
          if $DEBUG;

        # TODO: Add $inc, $push, etc. capabilities
        $self->_collection->update(
            { _id    => MongoDB::OID->new( value => $self->id ) },
            { '$set' => $self->{_changes} } );
        my $result = $self->_database->last_error;
        if ( $result->{n} != 1 ) {
            warn 'Error updating ' . $self->id . ': ' . $result->{err};
        }
    }

    return $self;
}

=head2 delete

  $object->delete;

Remove a document from the database.

=cut

sub delete {
    my $self = shift;

    return 0
      if $self->id
          and (
              !$self->_collection->remove(
                  { _id => MongoDB::OID->new( value => $self->id ) }
              )
          );

    return 1;
}

=head2 to_time

  my $timestamp = $object->to_time($time_column);

Convertes an database timestamp to an unixtime value.

=cut

sub to_time {
    my $self = shift;
    my $key  = shift;

    # MongoDB doesn't need SQL format timestamp, use unixtime
    return $self->get_column($key);

}

=head2 from_time

  my $timestamp = $object->from_time($time_column,$timestamp);

Inserts a timestamp into the database (converting it to database format).

=cut

sub from_time {
    my $self       = shift;
    my $key        = shift;
    my $time_value = shift;

    # MongoDB doesn't need any specific timestamp format, use unixtime
    return $self->set_column( $key, $time_value );
}

=head1 INTERNAL METHODS

Advoid calling them directly unless you really know what you're doing.

=head2 import

Copy some 'use' arguments to internal structures.

=cut

sub import {
    my $class = shift;
    my %args  = @_;

    my $objclass = caller(0);

    # Copy values to local cache
    $SERVER{$objclass}     = $args{server}     if defined( $args{server} );
    $DATABASE{$objclass}   = $args{database}   if defined( $args{database} );
    $COLLECTION{$objclass} = $args{collection} if defined( $args{collection} );

    if ( ref( $args{keys} ) eq 'ARRAY' ) {
        for my $key ( @{ $args{keys} } ) {
            *{ $objclass . '::' . $key } =
              sub { return shift->getset_column( $key, @_ ) };
        }
    } elsif ( ref( $args{keys} ) eq 'HASH' ) {
        for my $key ( keys %{ $args{keys} } ) {
            if (ref($args{keys}->{$key})) {
                my $class = lcfirst($key);
                $class =~ s/\W+/\_/g;
                $class = $objclass.'::'.$class;

                @{ 'YAWF::Object::MongoDB::Data::'.$class. '::ISA' } = ('YAWF::Object::MongoDB::Data');
                ${ 'YAWF::Object::MongoDB::Data::'.$class. '::PARENT_CLASS' } = $objclass;

                if (ref($args{keys}->{$key}) eq 'HASH') {
                    # TODO: Process deep data objects
                    for my $subkey (keys(%{$args{keys}->{$key}})) {
                        *{ 'YAWF::Object::MongoDB::Data::'.$class . '::' . $subkey } =
                          (ref($args{keys}->{$key}->{$subkey}) eq 'CODE') ? $args{keys}->{$key}->{$subkey} :
                          sub { return shift->YAWF::Object::MongoDB::Data::getset_column( $subkey, @_ ) };
                    }
                } elsif (ref($args{keys}->{$key}) eq 'ARRAY') {
                    # TODO: Process deep data objects
                    for my $subkey (@{$args{keys}->{$key}}) {
                        *{ 'YAWF::Object::MongoDB::Data::'.$class . '::' . $subkey } =
                          sub { return shift->getset_column( $subkey, @_ ) };
                    }
                }

                *{ $objclass. '::' . $key } =
                  sub {
                      my $self = shift;
                      
                      if (!$self->{_subobj}->{$key}) {
                        $self->set_column($key,{}) unless $self->get_column($key);
                        $self->{_subobj}->{$key} = bless {
                                _parent => $self, # Top object
                                _top => $key,     # Key of top object
                                _data => $self->get_column($key), # Hash-ref of my parent
                            },'YAWF::Object::MongoDB::Data::'.$class;
                        
                      }
                      
                      return $self->{_subobj}->{$key};
                  };

            } else {
                *{ $objclass . '::' . $key } =
                  sub { return shift->getset_column( $key, @_ ) };
            }
        }
    }

}

=head2 _unify

Reduce the parent object to a class name.

=cut

sub _unify {
    my $self = shift;

    return ref($self) if ref($self);    # Blessed object
    return $self;                       # Class
}

=head2 _server

Get a server connection handler

=cut

sub _server {
    my $self = shift;

    my $class = $self->_unify;

    my $server =
         $class::SERVER
      || $SERVER{$class}
      || ( ($YAWF && YAWF->SINGLETON && YAWF->SINGLETON->config) ? YAWF->SINGLETON->config->{mongodb}->{server} : 0 )
      || $DEFAULT_SERVER;

    if ( !defined( $SERVER_CACHE{$server} ) ) {

        my %conn_args;
        if ( $server =~ /^(.+?)\:(.+?)\@/ ) {
            $conn_args{username} = $1;
            $conn_args{password} = $1;
        }
        if ( $server =~ /^(\w+)\:(\d+)$/ ) {
            $conn_args{host} = $1;
            $conn_args{port} = $2;
        } elsif ($server) {
            $conn_args{host} = $server;
        }

        $SERVER_CACHE{$server} ||= MongoDB::Connection->new(%conn_args);
        warn 'No connection to MongoDB for ' . $class
          unless $SERVER_CACHE{$server};
    }

    return $SERVER_CACHE{$server};
}

=head2 _database

Get a database handler

=cut

sub _database {
    my $self = shift;

    my $class = $self->_unify;

    my $database =
         $class::DATABASE
      || $DATABASE{$class}
      || ( ($YAWF && YAWF->SINGLETON && YAWF->SINGLETON->config) ? YAWF->SINGLETON->config->{mongodb}->{database} : 0 )
      || $DEFAULT_DATABASE;

    $DATABASE_CACHE{$database} ||= $self->_server->$database;

    return $DATABASE_CACHE{$database};
}

=head2 _collection

Get a collection handler

=cut

sub _collection {
    my $self = shift;

    my $class = $self->_unify;

    my $collection =
         $class::COLLECTION
      || $COLLECTION{$class}
      || ( ($YAWF && YAWF->SINGLETON && YAWF->SINGLETON->config) ? YAWF->SINGLETON->config->{mongodb}->{collection} : 0 )
      || $DEFAULT_COLLECTION;

    $COLLECTION_CACHE{$collection} ||= $self->_database->$collection;

    return $COLLECTION_CACHE{$collection};
}

=head2 _resolv_sort

Resolv order_by - argument of ->list

=cut

sub _resolv_sort {
    my $self  = shift;
    my $item  = shift;
    my $order = shift || 1;    # -1 = desc, 1 = inc (default)

    if ( ref($item) eq 'HASH' ) {
        return $self->_resolv_sort( $item->{-asc},  1 )  if $item->{-asc};
        return $self->_resolv_sort( $item->{-desc}, -1 ) if $item->{-desc};
    } elsif ( ref($item) eq 'ARRAY' ) {
        return map { $self->_resolv_sort( $_, $order ); } @{$item};
    } else {

        # Only one key given, sort inc
        return { $item => $order };
    }
}

1;

=head1 DEBUGGING

Set environment variable YAWF_MONGODB_TRACE to 1 to enable debug warn's to STDERR.

=head1 AUTHOR

Sebastian Willing, C<< <sewi at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-yawf-object-mongodb at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=YAWF-Object-MongoDB>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc YAWF::Object::MongoDB


You can also look for information at:

=over 4

=item * Authors Blog

L<http://www.pal-blog.de/tag/yawf>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=YAWF-Object-MongoDB>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/YAWF-Object-MongoDB>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/YAWF-Object-MongoDB>

=item * Search CPAN

L<http://search.cpan.org/dist/YAWF-Object-MongoDB/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Sebastian Willing.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut
