use Modern::Perl;

# A Pandoc::Incremental object is used to build a pandoc document
# incrementally. It is a stack of Pandoc block elements which starts out
# as just a Document, which remains the bottom of the stack forever.
# Arbitrary elements can be added using &append, which appends to the
# block at the top of the stack. This may either be a Pandoc::* element
# (which is added verbatim) or any other object which must be converted
# to a Pandoc element via a call to the &_pandocify method.
#
# To handle your custom kind of object, inherit from Pandoc::Incremental
# and provide a suitable implementation of _pandocify.
#
# Block elements can be pushed onto the stack using &enter and removed
# again with &leave as well. On enter, they are also appended to the
# current top of the stack. It is not impossible to pop off the root
# document.

package Pandoc::Incremental;

use Pandoc::Elements;

sub new {
    my $class = shift;
    my $meta = shift // {};
    my $doc = Document($meta, []);
    bless [ $doc ], $class;
}

sub document {
    my $self = shift;
    $self->[0]
}

sub append {
    my $self = shift;
    my $elt = $self->[-1];
    for my $new (@_) {
        $new = $self->_pandocify($new)
            unless ref($new) =~ '^Pandoc::';
        push @{$elt->content}, $new;
    }
}

sub top {
    my $self = shift;
    $self->[-1]
}

sub enter {
    my $self = shift;
    my $next = shift // Div(['', [], []], []);
    warn "entering non-block element @{[ ref($next) ]}"
        unless $next->is_block;
    $self->append($next);
    push @$self, $next;
}

sub leave {
    my $self = shift;
    if (@$self == 1) {
        warn "attempt to leave the entire document";
        return;
    }
    pop @$self;
}

sub _pandocify {
    my $self = shift;
    my $obj = shift;
    warn "cannot pandocify @{[ ref($obj) ]}";
    return undef;
}

":wq"
