use Modern::Perl;

use FFI::Platypus;
use FFI::CheckLib qw(find_lib_or_exit);

my $ffi = FFI::Platypus->new(api => 1);
$ffi->lib(find_lib_or_exit lib => 'clang');
$ffi->mangler(sub { "clang_" . shift });

package Clang::String {
    use overload (
        '""' => sub { shift->_stringify },
    );

	$ffi->custom_type(ClangString => {
		native_type    => 'opaque',
		native_to_perl => sub { bless \$_[0], 'Clang::String' },
		perl_to_native => sub { ${+shift} },
	});

	$ffi->attach([ getCString    => '_stringify' ] => [ 'ClangString' ] => 'string');
	$ffi->attach([ disposeString => 'DESTROY'    ] => [ 'ClangString' ] => 'void');
}

package Clang {
    $ffi->attach([ getClangVersion => 'version' ] => [] => 'ClangString');
}

package Clang::Index {
    $ffi->custom_type(ClangIndex => {
        native_type => 'opaque',
        native_to_perl => sub { bless \$_[0], 'Clang::Index' },
        perl_to_native => sub { ${+shift} },
    });

    $ffi->attach([ createIndex  => '_new' ] => [ 'int', 'int' ] => 'ClangIndex');
    $ffi->attach([ disposeIndex => 'DESTROY' ] => [ 'ClangIndex' ] => 'void');

    sub new {
        my (undef, $exclude_pch, $display_diag) = @_;
        $exclude_pch  //= 1;
        $display_diag //= 0;
        _new($exclude_pch, $display_diag)
    }
}

package Clang::Type {
    use FFI::Platypus::Record;

    record_layout_1($ffi,
        'enum'      => '_kind',
        'opaque[2]' => '_data',
    );

    $ffi->type('record(Clang::Type)' => 'ClangType');

    use overload (
        '""' => sub { shift->_stringify },
    );

    $ffi->attach([ getTypeSpelling => '_stringify' ] => [ 'ClangType' ] => 'ClangString');
}

package Clang::File {
    use overload (
        '""' => sub {
            my $self = shift;
            return '<no file>' unless $$self;
            $self->_stringify
        },
        'bool' => sub {
            my $self = shift;
            defined($$self)
        },
    );

    $ffi->custom_type(ClangFile => {
        native_type => 'opaque',
        native_to_perl => sub { bless \$_[0], 'Clang::File' },
        perl_to_native => sub { ${+shift} },
    });

    $ffi->attach([ getFileName => '_stringify' ] => [ 'ClangFile' ] => 'ClangString');
}

package Clang::Location {
    use FFI::Platypus::Record;

    record_layout_1($ffi,
        'opaque[2]' => '_ptr_data',
        'uint'      => '_int_data',
    );

    $ffi->type('record(Clang::Location)' => 'ClangLocation');

    use overload (
        '""' => sub {
            my $self = shift;
            $self->file . ":" . $self->line . ":" . $self->column
        },
    );

    $ffi->attach([ getFileLocation=> '_unpack' ] => [ 'ClangLocation', 'opaque*', 'uint*', 'uint*', 'uint*' ] => 'void');

    sub unpack {
        my ($file, $line, $column, $offset);
        shift->_unpack(\$file, \$line, \$column, \$offset);
        my $which = shift;
        my @all = (bless(\$file, 'Clang::File'), $line, $column, $offset);
        return defined($which) ? $all[$which] : @all;
    }

    sub file   { shift->unpack(0) }
    sub line   { shift->unpack(1) }
    sub column { shift->unpack(2) }
    sub offset { shift->unpack(3) }
}

package Clang::Comment {
    use FFI::Platypus::Record;

    record_layout_1($ffi,
        'opaque' => '_astnode',
        'opaque' => '_tu',
    );

    $ffi->type('record(Clang::Comment)' => 'ClangComment');

    use overload (
        '""' => \&html,
        'bool' => sub {
            shift->kind != 0
        },
    );

    $ffi->attach([ Comment_getKind => 'kind' ] => [ 'ClangComment' ] => 'enum');
    $ffi->attach([ FullComment_getAsHTML => '_html' ] => [ 'ClangComment' ] => 'ClangString');

    sub html {
        my $self = shift;
        return '' unless $self;
        $self->_html
    }
}

package Clang::Cursor::Kind {
    use overload (
        '""' => sub { shift->_stringify },
    );

    $ffi->custom_type(ClangCursorKind => {
        native_type => 'enum',
        native_to_perl => sub { bless \$_[0], 'Clang::Cursor::Kind' },
        perl_to_native => sub { ${+shift} },
    });

    $ffi->attach([ getCursorKindSpelling => '_stringify' ] => [ 'ClangCursorKind' ] => 'ClangString');
}

package Clang::Cursor {
    use FFI::Platypus::Record;

    record_layout_1($ffi,
        'enum'      => '_kind',
        'int'       => '_xdata',
        'opaque[3]' => '_data',
    );

    $ffi->type('record(Clang::Cursor)' => 'ClangCursor');

    use overload (
        '""' => sub { shift->_stringify },
    );

    $ffi->attach([ getCursorSpelling => '_stringify' ] => [ 'ClangCursor' ] => 'ClangString');
    $ffi->attach([ getCursorLocation => 'location' ] => [ 'ClangCursor' ] => 'ClangLocation');
    $ffi->attach([ getCursorType => 'type' ] => [ 'ClangCursor' ] => 'ClangType');
    $ffi->attach([ getCursorKind => 'kind' ] => [ 'ClangCursor' ] => 'ClangCursorKind');

    # Platypus says I can (experimentally) pass records as closure arguments
    # as well, but I don't see how. The closure type regex forbids the 'record()'
    # syntax inside the parenthesized closure argument list and non-native
    # types (aliases) are refused. So I'm falling back to an Inline::C routine
    # now for the callback. I think I'd blame the FFI-unfriendly interface of
    # libclang here, though.

	use Inline C => config => libs => '-lclang';
    use Inline C => <<'EOF';
	#include <clang-c/Index.h>

    /*
     * Clang::Cursor is an FFI::Platypus::Record. Per Platypus source code,
     * this means we deal with a scalar reference to a buffer holding the
     * CXCursor data. In _fill_children, we have to unpack that, while in
     * visitor we have to create new blessed Clang::Cursor in the reverse.
     */

	enum CXChildVisitResult visitor(CXCursor cursor, CXCursor parent, CXClientData data) {
        AV *children = data;
        SV *child = sv_setref_pvn(newSV(0), "Clang::Cursor", &cursor, sizeof(cursor));
        av_push(children, child);
        return CXChildVisit_Continue;
	}

    AV *_children(SV *cursorref) {
        AV *children = (AV *) sv_2mortal((SV *) newAV());
        CXCursor cursor = *((CXCursor *) SvPV_nolen(SvRV(cursorref)));
        clang_visitChildren(cursor, visitor, children);
        return children;
    }
EOF

    sub children {
        @{ _children(shift) }
    }

    $ffi->attach([ Cursor_getParsedComment => 'comment' ] => [ 'ClangCursor' ] => 'ClangComment');
}

package Clang::Unit {
    use overload (
        '""' => sub { shift->_stringify },
    );

    $ffi->custom_type(ClangUnit => {
        native_type => 'opaque',
        native_to_perl => sub { bless \$_[0], 'Clang::Unit' },
        perl_to_native => sub { ${+shift} },
    });

    $ffi->attach([ createTranslationUnitFromSourceFile => '_from_source' ] =>
        [ 'ClangIndex', 'string', 'int', 'string[]', 'uint', 'opaque*' ] => 'ClangUnit');
    $ffi->attach([ disposeTranslationUnit     => 'DESTROY'    ] => [ 'ClangUnit' ] => 'void');
    $ffi->attach([ getTranslationUnitSpelling => '_stringify' ] => [ 'ClangUnit' ] => 'ClangString');
    $ffi->attach([ getTranslationUnitCursor   => 'cursor'     ] => [ 'ClangUnit' ] => 'ClangCursor');

    sub new {
        my (undef, $index, $file, @args) = @_;
        _from_source($index, $file, 0+ @args, \@args, 0, undef);
    }
}

package Clang::Documentation {
    use Exporter 'import';
    our @EXPORT = qw(read_with_documentation);

    sub read_with_documentation {
        my $file = shift;
        my $index = Clang::Index->new;
        my $tu = Clang::Unit->new($index => $file => '-Wdocumentation' => '-fparse-all-comments');
    }
}

":wq"
