use 5.008;
use strict;
use warnings;

package Sub::HandlesVia::CodeGenerator;

our $AUTHORITY = 'cpan:TOBYINK';
our $VERSION   = '0.022';

use Class::Tiny (
	qw(
		toolkit
		target
		attribute
		attribute_spec
		generator_for_slot
		generator_for_get
		generator_for_set
		generator_for_simple_set
		generator_for_default
		isa
		coerce
		method_installer
	),
	{
		env => sub {
			return {};
		},
		is_method => sub {
			return !!1;
		},
		get_is_lvalue => sub {
			return !!0;
		},
		set_checks_isa => sub {
			return !!0;
		},
		set_strictly => sub {
			return !!1;
		},
		generator_for_args => sub {
			return sub {
				'@_[1..$#_]';
			};
		},
		generator_for_arg => sub {
			return sub {
				@_==1 or die;
				my $n = shift;
				"\$_[$n]";
			};
		},
		generator_for_argc => sub {
			return sub {
				'(@_-1)';
			};
		},
		generator_for_currying => sub {
			return sub {
				@_==1 or die;
				my $arr = shift;
				"splice(\@_,1,0,$arr);";
			};
		},
		generator_for_usage_string => sub {
			return sub {
				@_==2 or die;
				my $method_name = shift;
				my $guts = shift;
				"\$instance->$method_name($guts)";
			};
		},
		generator_for_self => sub {
			return sub {
				'$_[0]';
			};
		},
	},
);

my @generatable_things = qw(
	slot get set simple_set default arg args argc currying usage_string self
);
for my $thing ( @generatable_things ) {
	my $generator = "generator_for_$thing";
	my $method_name = "generate_$thing";
	my $method = sub {
		my $gen = shift;
		local ${^GENERATOR} = $gen;
		return $gen->$generator->( @_ );
	};
	no strict 'refs';
	*$method_name = $method;
}

sub generate_and_install_method {
	my ( $self, $method_name, $handler ) = @_;
	
	$self->install_method(
		$method_name,
		$self->generate_coderef_for_handler( $method_name, $handler ),
	);
}

{
	my $sub_rename;
	if ( eval { require Sub::Util } ) {
		$sub_rename = Sub::Util->can('set_subname');
	}
	elsif ( eval { require Sub::Name } ) {
		$sub_rename = Sub::Name->can('subname');
	}
	
	sub install_method {
		my ( $self, $method_name, $coderef ) = @_;
		my $target = $self->target;
		
		eval {
			$coderef = $sub_rename->( "$target\::$method_name", $coderef )
		} if ref $sub_rename;
		
		if ( $self->method_installer ) {
			$self->method_installer->( $method_name, $coderef );
		}
		else {
			no strict 'refs';
			*{"$target\::$method_name"} = $coderef;
		}
	}
}

sub generate_coderef_for_handler {
	my ( $self, $method_name, $handler ) = @_;
	
	my $ec_args = $self->_generate_ec_args_for_handler( $method_name, $handler );
	
#	warn join("\n", @{$ec_args->{source}});
#	for my $key (sort keys %{$ec_args->{environment}}) {
#		warn ">> $key : ".ref($ec_args->{environment}{$key});
#		if ( ref($ec_args->{environment}{$key}) eq 'REF' and ref(${$ec_args->{environment}{$key}}) eq 'CODE' ) {
#			require B::Deparse;
#			warn B::Deparse->new->coderef2text(${$ec_args->{environment}{$key}});
#		}
#	}
	
	require Eval::TypeTiny;
	Eval::TypeTiny::eval_closure( %$ec_args );
}

sub _generate_ec_args_for_handler {
	my ( $self, $method_name, $handler ) = @_;
	
	# COPY of $self->env
	my $env = { %{$self->env} };
	
	my $code = [
		'sub {',
		sprintf( 'package %s::__SANDBOX__;', __PACKAGE__ ),
	];
	
	my $sig_was_checked = $self->__process_sigcheck(
		$method_name, $handler, $env, $code,
	);
	$self->__process_currying(
		$method_name, $handler, $env, $code,
	);
	$self->__process_handler_template(
		$method_name, $handler, $env, $code,
		$sig_was_checked,
	);
	$self->__process_chaining(
		$method_name, $handler, $env, $code,
	);
	
	push @$code, "}";
	
	$handler->_tweak_env( $env );
	
	return {
		source      => $code,
		environment => $env,
		description => sprintf(
			"%s=%s",
			$method_name || '__ANON__',
			$handler->name,
		),
	};
}

# Insert code into method for signature validation.
#
sub __process_sigcheck {
	my ( $self, $method_name, $handler, $env, $code ) = @_;
	my $sig_was_checked = 0;

	if ( @{ $handler->signature || [] } ) {
		require Type::Params;
		unshift @$code, 'my $__sigcheck;';
		$env->{'@__sig'} = $handler->signature;
		push @$code, '$__sigcheck||=Type::Params::compile(1, @__sig);@_=&$__sigcheck;';
		++$sig_was_checked;
	}
	else {
		my $min_args = $handler->has_min_args ? $handler->min_args : 0;
		my $max_args = $handler->max_args;
		my $usg = sprintf(
			'do { require Carp; Carp::croak("Wrong number of parameters; usage: ".%s) }',
			B::perlstring( $self->generate_usage_string( $method_name, $handler->usage ) ),
		);
		
		if (defined $min_args and defined $max_args and $min_args==$max_args) {
			push @$code, sprintf('@_==%d or %s;', $min_args + 1, $usg);
		}
		elsif (defined $min_args and defined $max_args) {
			push @$code, sprintf('(@_ >= %d and @_ <= %d) or %s;', $min_args + 1, $max_args + 1, $usg);
		}
		elsif (defined $min_args) {
			push @$code, sprintf('@_ >= %d or %s;', $min_args + 1, $usg);
		}
	}
	
	return $sig_was_checked;
}

# Insert code into method for currying.
#
sub __process_currying {
	my ( $self, $method_name, $handler, $env, $code ) = @_;
	
	if ( my $curried = $handler->curried ) {
		if ( grep ref, @$curried ) {
			$env->{'@curry'} = $curried;
			push @$code, $self->generate_currying('@curry');
		} else {
			require B;
			my $values = join(
				',',
				map { defined($_) ? B::perlstring($_) : 'undef' } @$curried,
			);
			push @$code, $self->generate_currying( "($values)" );
		}
	}
	
	return;
}

sub __getter_code {
	my ( $self, $method_name, $handler, $env, $code ) = @_;
	
	my $wrapper;
	my $getter = $self->generate_get();
	my $getter_is_lvalue = $self->get_is_lvalue;
	
	# If the getter is known to be a reference, but there's a complicated
	# way to fetch it (perhaps involving a lazy builder) then get it
	# straight away, and store it in $shv_ref_invocant so we dont' have
	# to keep doing the complicated thing.
	#
	if ($handler->name =~ /^(Array|Hash):/) {
		if ($getter !~ /^
			\$                 # scalar access
			[^\W0-9]\w*        # normal-looking variable name (including $_)
			(?:                # then...
				(?:\-\>)?       #     dereference maybe
				[\[\{]          #     opening [ or {
				[\'\"]?         #     quote maybe
				\w+             #     word characters (includes digits)
				[\'\"]?         #     quote maybe
				[\]\}]          #     closing ] or }
			){0,3}             # ... up to thrice
			$/x) {
			push @$code, "my \$shv_ref_invocant = do { $getter };";
			$getter = '$shv_ref_invocant';
			$getter_is_lvalue = 1;
		}
	}
	elsif ($getter !~ /^
		\$                 # scalar access
		[^\W0-9]\w*        # normal-looking variable name (including $_)
		(?:                # then...
			(?:\-\>)?       #     dereference maybe
			[\[\{]          #     opening [ or {
			[\'\"]?         #     quote maybe
			\w+             #     word characters (includes digits)
			[\'\"]?         #     quote maybe
			[\]\}]          #     closing ] or }
		){0,3}             # ... up to thrice
		$/x
		and ( $handler->template.($handler->lvalue_template||'') =~ /\$GET/ )
		and $handler->allow_getter_shortcuts) {
		# Getter is kind of complex (maybe includes function calls, etc
		# So only do it once.
		$getter =~ s/%/%%/g;
		$wrapper = "do { my \$shv_real_invocant = $getter; %s }";
		$getter  = '$shv_real_invocant';
	}
	
	return ( $getter, $getter_is_lvalue, $wrapper );
}

# Figure out which method to use to generate a setter.
#
sub __generate_set_method {
	my ( $self, $method_name, $handler, $env, $code, $type_check_needed, $getter_is_lvalue ) = @_;
	
	my $return = 'generate_set';
	
	# If no type check is needed, a simplified version of the setter
	# exists, we haven't been told to always set strictly, and the
	# setter isn't checking isa, we should use the simplified setter.
	#
	if ( !$$type_check_needed
	and  defined $self->generator_for_simple_set
	and  !$self->set_strictly
	and  !$self->set_checks_isa ) {
		$return = 'generate_simple_set';
	}
	
	# If a type check is needed, but the setter doesn't do type checks,
	# then wrap the setter. Now the setter does the type check, so
	# we no longer need to.
	#
	if ( $$type_check_needed and not $self->set_checks_isa ) {
		my $orig_set = $return;
		$$getter_is_lvalue = 0;
		$return = sub {
			my ( $me, $value_code ) = @_;
			$me->$orig_set( sprintf(
				'do { my $unchecked = %s; %s }',
				$value_code,
				$me->isa->inline_assert( '$unchecked', '$finaltype' ),
			) );
		};
		$env->{'$finaltype'} = \( $self->isa );
		$$type_check_needed = 0;
	}
	
	return $return;
}

sub __process_handler_template {
	my ( $self, $method_name, $handler, $env, $code, $sig_was_checked ) = @_;
	
	# If the handler is a mutator, then a type check will be
	# needed later when setting the new value.
	#
	my $type_check_needed = $handler->is_mutator;
	if ( $handler->no_validation_needed or not $self->isa ) {
		$type_check_needed = 0;
	}
	
	# The handler can define some additional validation to be performed
	# on arguments either now or later, such that if this additional
	# validation is performed, the type check we were planning later
	# will be known to be unnecessary.
	#
	my $add_later;
	my $additional_validation_opts;
	if ( $type_check_needed and defined $handler->additional_validation ) {
		$additional_validation_opts = $handler->_real_additional_validation->(
			$handler,
			$sig_was_checked,
			$self,
		) || {};
		if ($additional_validation_opts->{add_later}) {
			$add_later = $additional_validation_opts->{code};
			$env->{$_} = $additional_validation_opts->{env}{$_}
				for keys %{ $additional_validation_opts->{env} };
			$type_check_needed = 0;
		}
		elsif ($additional_validation_opts->{code}) {
			push @$code, $additional_validation_opts->{code};
			$env->{$_} = $additional_validation_opts->{env}{$_}
				for keys %{ $additional_validation_opts->{env} };
			$type_check_needed = 0;
		}
	}
	
	my ( $getter, $getter_is_lvalue, $getter_wrapper ) =
		$self->__getter_code( $method_name, $handler, $env, $code );
	
	my $generate_set_method = $self->__generate_set_method(
		$method_name, $handler, $env, $code,
		\$type_check_needed, \$getter_is_lvalue,
	);

	my $generate_arg_method =
		$additional_validation_opts->{arg}  || 'generate_arg';
	my $generate_argc_method =
		$additional_validation_opts->{argc} || 'generate_argc';
	my $generate_args_method =
		$additional_validation_opts->{args} || 'generate_args';
	
	# Fetch code template for this method.
	#
	my $template = $handler->template;
	
	# But if the getter is an lvalue, the handler has a special template
	# for lvalues, we haven't been told to set strictly, and we have taken
	# care of any type checks, then use the special lvalue template.
	#
	if ( $getter_is_lvalue
	and  $handler->lvalue_template
	and  !$self->set_strictly
	and  !$type_check_needed ) {
		$template = $handler->lvalue_template;
	}
	
	$template =~ s/\$SELF/$self->generate_self()/eg;
	$template =~ s/\$SLOT/$self->generate_slot()/eg;
	$template =~ s/\$GET/$getter/g;
	$template =~ s/\$ARG\[([0-9]+)\]/$self->$generate_arg_method($1)/eg;
	$template =~ s/\$ARG/$self->$generate_arg_method(1)/eg;
	$template =~ s/\#ARG/$self->$generate_argc_method()/eg;
	$template =~ s/\@ARG/$self->$generate_args_method()/eg;
	$template =~ s/«(.+?)»/$self->$generate_set_method($1)/eg;
	$template =~ s/\$DEFAULT/$self->generate_default($self, $handler)/eg;
	
	my $body = $getter_wrapper
		? sprintf($getter_wrapper, $template)
		: $template;
	
	$body =~ s/\"?____VALIDATION_HERE____\"?/$add_later/
		if defined $add_later;
	
	push @$code, $body;
	return;
}

sub __process_chaining {
	my ( $self, $method_name, $handler, $env, $code ) = @_;
	
	push @$code, ';' . $self->generate_self,
		if $handler->is_chainable;
	return;
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

Sub::HandlesVia::CodeGenerator - looks at a Handler and generates a string of Perl code for it

=head1 DESCRIPTION

Sub::HandlesVia toolkits create a code generator for each attribute they're
dealing with, and use the code generator to generate Perl code for one or
more delegated methods.

=head1 CONSTRUCTORS

=head2 C<< new( %attributes ) >>

Standard Moose-like constructor.

=head1 ATTRIBUTES

=head2 C<toolkit> B<Object>

The toolkit which made this code generator.

=head2 C<target> B<< ClassName|RoleName >>

The target package for generated methods.

=head2 C<attribute> B<< Str|ArrayRef >>

The attribute delegated to.

=head2 C<attribute_spec> B<< HashRef >>

Informational only.

=head2 C<is_method> B<< Bool >>

Indicates whether the generated code should be methods rather than functions.
This defaults to true, and false isn't really tested or well-defined.

=head2 C<env> B<< HashRef >>

Variables which need to be closed over when compiling coderefs.

=head2 C<isa> B<< Maybe[TypeTiny] >>

The type constraint for the attribute.

=head2 C<coerce> B<< Bool >>

Should the attribute coerce?

=head2 C<method_installer> B<CodeRef>

A coderef which can be called with C<< $method_name >> and C<< $coderef >>,
will install the method. Note that it isn't passed the package to install
into (which can be found in C<target>), so that would need to be closed
over.

=head2 C<generator_for_slot> B<< CodeRef >>

A coderef which if called, generates a string like C<< '$_[0]' >>.

Has a sensible default.

=head2 C<generator_for_slot> B<< CodeRef >>

A coderef which if called, generates a string like C<< '$_[0]{attrname}' >>.

=head2 C<generator_for_get> B<< CodeRef >>

A coderef which if called, generates a string like C<< '$_[0]->attrname' >>.

=head2 C<generator_for_set> B<< CodeRef >>

A coderef which if called with a parameter, generates a string like
C<< "\$_[0]->_set_attrname( $parameter )" >>.

=head2 C<generator_for_simple_set> B<< CodeRef >>

A coderef which if called with a parameter, generates a string like
C<< "\$_[0]{attrname} = $parameter" >>.

=head2 C<generator_for_simple_default> B<< CodeRef >>

A coderef which if called with a parameter, generates a string like
C<< 'undef' >> or C<< 'q[]' >> or C<< '{}' >>.

=head2 C<generator_for_args> B<< CodeRef >>

A coderef which if called, generates a string like C<< '@_[1..$#_]' >>.

Has a sensible default.

=head2 C<generator_for_argc> B<< CodeRef >>

A coderef which if called, generates a string like C<< '$#_' >>.

Has a sensible default.

=head2 C<generator_for_argc> B<< CodeRef >>

A coderef which if called with a parameter, generates a string like
C<< "\$_[$parameter + 1]" >>.

Has a sensible default.

=head2 C<generator_for_currying> B<< CodeRef >>

A coderef which if called with a parameter, generates a string like
C<< "splice(\@_,1,0,$parameter);" >>.

Has a sensible default.

=head2 C<generator_for_usage_string> B<< CodeRef >>

The default is this coderef:

  sub {
    @_==2 or die;
    my $method_name = shift;
    my $guts = shift;
    return "\$instance->$method_name($guts)";
  }

=head2 C<get_is_lvalue> B<Bool>

Indicates wheter the code generated by C<generator_for_get>
will be suitable for used as an lvalue.

=head2 C<set_checks_isa> B<Bool>

Indicates wheter the code generated by C<generator_for_set>
will do type checks.

=head2 C<set_strictly> B<Bool>

Indicates wheter we want to ensure that the setter is always called,
and we should not try to bypass it, even if we have an lvalue getter.

=head1 METHODS

=head2 C<< generate_and_install_method( $method_name, $handler ) >>

Given a handler and a method name, will generate a coderef for the handler
and install it into the target package.

=head2 C<< generate_coderef_for_handler( $method_name, $handler ) >>

As above, but just returns the coderef rather than installs it.

=head2 C<< install_method( $method_name, $coderef ) >>

Installs a coderef into the target package with the given name.

=head1 BUGS

Please report any bugs to
L<https://github.com/tobyink/p5-sub-handlesvia/issues>.

=head1 SEE ALSO

L<Sub::HandlesVia>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2020, 2022 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
