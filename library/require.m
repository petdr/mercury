%-----------------------------------------------------------------------------%
% Copyright (C) 1993-1999, 2003, 2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%

:- module require.

% Main author: fjh.
% Stability: medium to high.

% This module provides features similar to <assert.h> in C.

%-----------------------------------------------------------------------------%
:- interface.

:- type software_error ---> software_error(string).

:- pred error(string).
:- mode error(in) is erroneous.

%	error(Message).
%		Throw a `software_error(Message)' exception.
%		This will normally cause execution to abort with an error
%		message.

:- func func_error(string) = _.
:- mode func_error(in) = out is erroneous.

%	func_error(Message)
%		An expression that results in a `software_error(Message)'
%		exception being thrown.

:- pred	require(pred, string).
:- mode	require((pred) is semidet, in) is det.

%	require(Goal, Message).
%		Call goal, and call error(Message) if Goal fails.
%		This is not as useful as you might imagine, since it requires
%		that the goal not produce any output variables.  In
%		most circumstances you should use an explicit if-then-else
%		with a call to error/1 in the "else".

:- pred report_lookup_error(string, K, V).
:- mode report_lookup_error(in, in, unused) is erroneous.

%	report_lookup_error(Message, Key, Value)
%		Call error/1 with an error message that is appropriate for
%		the failure of a lookup operation involving the specified
%		Key and Value.  The error message will include Message
%		and information about Key and Value.

:- pred report_lookup_error(string, K).
:- mode report_lookup_error(in, in) is erroneous.

%	report_lookup_error(Message, Key)
%		Call error/1 with an error message that is appropriate for
%		the failure of a lookup operation involving the specified
%		Key.  The error message will include Message
%		and information about Key.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module string, list, std_util, exception.

require(Goal, Message) :-
	( call(Goal) ->
		true
	;
		error(Message),
		fail
	).

%-----------------------------------------------------------------------------%

report_lookup_error(Msg, K, V) :-
	KeyType = type_name(type_of(K)),
	ValueType = type_name(type_of(V)),
	functor(K, Functor, Arity),
	( Arity = 0 ->
		FunctorStr = Functor
	;
		string__int_to_string(Arity, ArityStr),
		string__append_list([Functor, "/", ArityStr], FunctorStr)
	),
	string__append_list(
		[Msg,
		"\n\tKey Type: ",
		KeyType,
		"\n\tKey Functor: ",
		FunctorStr,
		"\n\tValue Type: ",
		ValueType
		],
		ErrorString),
	error(ErrorString).

report_lookup_error(Msg, K) :-
	KeyType = type_name(type_of(K)),
	functor(K, Functor, Arity),
	( Arity = 0 ->
		FunctorStr = Functor
	;
		string__int_to_string(Arity, ArityStr),
		string__append_list([Functor, "/", ArityStr], FunctorStr)
	),
	string__append_list(
		[Msg,
		"\n\tKey Type: ",
		KeyType,
		"\n\tKey Functor: ",
		FunctorStr
		],
		ErrorString),
	error(ErrorString).

%-----------------------------------------------------------------------------%

% Hopefully error/1 won't be called often (!), so no point inlining it.
:- pragma no_inline(error/1). 

% We declare error/1 to be terminating so that all of the standard library
% will treat it as terminating.
:- pragma terminates(error/1).

error(Message) :- 
	throw(software_error(Message)).

% Hopefully func_error/1 won't be called often (!), so no point inlining it.
:- pragma no_inline(func_error/1). 

func_error(Message) = _ :-
	error(Message).

:- end_module require.

%-----------------------------------------------------------------------------%
