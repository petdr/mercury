%-----------------------------------------------------------------------------%
% Copyright (C) 2000 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Module:	sr_profile
% Main authors: nancy

:- module sr_profile.

:- interface.

:- import_module io, int, string. 

:- type profiling_info ---> 
		prof(
			% general counting of procedures
			procs_defined	:: int, 
			reuse_procs	:: int,
			uncond_reuse_procs :: int,
			procs_counted	:: int, 

			% only counting about exported procedures
			exported_procs  :: int,
			exported_reuse_procs :: int, 
			exported_uncond_reuse_procs ::int, 
	
			% info about the aliases	
			aliases		:: int, 
			bottom_procs	:: int,
			top_procs	:: int, 
	
			deconstructs 	:: int, 
			direct_reuses 	:: int,
			direct_conditions :: int, 	% not used 
			

			pred_calls 	:: int, 
			reuse_calls	:: int, 
			no_reuse_calls 	:: int  	
		).

:- pred init( profiling_info::out ) is det.

:- pred inc_procs_defined( profiling_info::in, profiling_info::out ) is det.
:- pred inc_reuse_procs( profiling_info::in, profiling_info::out ) is det.
:- pred inc_uncond_reuse_procs( profiling_info::in, 
			profiling_info::out ) is det.
:- pred inc_procs_counted( profiling_info::in, profiling_info::out ) is det.
:- pred inc_exported_procs( profiling_info::in, profiling_info::out ) is det.
:- pred inc_exported_reuse_procs( profiling_info::in, 
			profiling_info::out ) is det.
:- pred inc_exported_uncond_reuse_procs( profiling_info::in, 
			profiling_info::out ) is det.

:- pred inc_aliases( int::in, profiling_info::in, profiling_info::out ) is det.
:- pred inc_bottom_procs( profiling_info::in, profiling_info::out ) is det.
:- pred inc_top_procs( profiling_info::in, profiling_info::out ) is det.
:- pred inc_deconstructs( profiling_info::in, profiling_info::out ) is det.
:- pred inc_direct_reuses( profiling_info::in, profiling_info::out ) is det.
:- pred inc_direct_conditions( profiling_info::in, profiling_info::out ) is
det.
:- pred inc_pred_calls( profiling_info::in, profiling_info::out ) is det.
:- pred inc_reuse_calls( profiling_info::in, profiling_info::out ) is det.
:- pred inc_no_reuse_calls( profiling_info::in, profiling_info::out ) is det.


:- pred write_profiling( string::in, profiling_info::in, 
			io__state::di, io__state::uo ) is det. 

%-----------------------------------------------------------------------------%

:- implementation. 

:- import_module require, time, list. 

init( P ) :- 
	P = prof( 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0). 

inc_procs_defined( P0, P0 ^ procs_defined := (P0 ^ procs_defined + 1)).
inc_reuse_procs( P0, P0 ^ reuse_procs := (P0 ^ reuse_procs + 1)).
inc_uncond_reuse_procs( P0, 
		P0 ^ uncond_reuse_procs := (P0 ^ uncond_reuse_procs + 1)).
inc_procs_counted( P0, P0 ^ procs_counted := (P0 ^ procs_counted + 1)).
inc_exported_procs( P0, P0 ^ exported_procs := (P0 ^ exported_procs + 1)).
inc_exported_reuse_procs( P0, 
		P0 ^ exported_reuse_procs := (P0 ^ exported_reuse_procs + 1)).
inc_exported_uncond_reuse_procs( P0, 
	P0 ^ exported_uncond_reuse_procs 
			:= (P0 ^ exported_uncond_reuse_procs + 1)).
inc_aliases( N, P0, P0 ^ aliases := (P0 ^ aliases + N)).
inc_bottom_procs( P0, P0 ^ bottom_procs := (P0 ^ bottom_procs + 1)).
inc_top_procs( P0, P0 ^ top_procs := (P0 ^ top_procs + 1)).
inc_deconstructs( P0, P0 ^ deconstructs := (P0 ^ deconstructs + 1)).
inc_direct_reuses( P0, P0 ^ direct_reuses := (P0 ^ direct_reuses + 1)).
inc_direct_conditions( P0, P0 ^ direct_conditions := (P0 ^ direct_conditions + 1)).
inc_pred_calls( P0, P0 ^ pred_calls := (P0 ^ pred_calls + 1)).
inc_reuse_calls( P0, P0 ^ reuse_calls := (P0 ^ reuse_calls + 1)).
inc_no_reuse_calls( P0, P0 ^ no_reuse_calls := (P0 ^ no_reuse_calls + 1)). 

:- pred procs_defined( profiling_info::in, int::out) is det.
:- pred reuse_procs( profiling_info::in, int::out) is det.
:- pred uncond_reuse_procs( profiling_info::in, int::out) is det.
:- pred procs_counted( profiling_info::in, int::out) is det.
:- pred exported_procs( profiling_info::in, int::out) is det.
:- pred exported_reuse_procs( profiling_info::in, int::out) is det.
:- pred exported_uncond_reuse_procs( profiling_info::in, int::out) is det.
:- pred aliases( profiling_info::in, int::out) is det.
:- pred bottom_procs( profiling_info::in, int::out) is det.
:- pred top_procs( profiling_info::in, int::out) is det.
:- pred deconstructs( profiling_info::in, int::out) is det.
:- pred direct_reuses( profiling_info::in, int::out) is det.
:- pred direct_conditions( profiling_info::in,int::out) is det.
:- pred pred_calls( profiling_info::in, int::out) is det.
:- pred reuse_calls( profiling_info::in, int::out) is det.
:- pred no_reuse_calls( profiling_info::in, int::out) is det.


procs_defined( P0, P0 ^ procs_defined ).
reuse_procs( P0, P0 ^ reuse_procs ).
uncond_reuse_procs( P0, P0 ^ uncond_reuse_procs ).
procs_counted( P0, P0 ^ procs_counted ).
exported_procs( P0, P0 ^ exported_procs ).
exported_reuse_procs( P0, P0 ^ exported_reuse_procs ).
exported_uncond_reuse_procs( P0, P0 ^ exported_uncond_reuse_procs ).
aliases( P0, P0 ^ aliases ).
bottom_procs( P0, P0 ^ bottom_procs ).
top_procs( P0, P0 ^ top_procs ).
deconstructs( P0, P0 ^ deconstructs ).
direct_reuses( P0, P0 ^ direct_reuses ).
direct_conditions( P0, P0 ^ direct_conditions ).
pred_calls( P0, P0 ^ pred_calls ).
reuse_calls( P0, P0 ^ reuse_calls ).
no_reuse_calls( P0, P0 ^ no_reuse_calls ).

write_profiling( String, Prof ) --> 
	{ string__append(String, ".profile", String2) }, 
	io__open_output( String2, IOResult), 
	(
		{ IOResult = ok(Stream) },
		% top
		io__write_string(Stream, "Profiling output for module: "), 
		io__write_string(Stream, String), 
		io__nl(Stream),
		% date
		time__time( TimeT ), 
		{ TimeS = time__ctime(TimeT) }, 
		io__write_string(Stream, "Current time: "), 
		io__write_string(Stream, TimeS ), 
		io__nl(Stream), 
		io__nl(Stream), 
		io__write_string(Stream, "General info:\n"),
		write_prof_item( Stream, procs_defined, Prof, 
				"# declared procedures"), 
		write_prof_item( Stream, reuse_procs, Prof, 
				"# reuse-procedures"), 
		write_prof_item( Stream, uncond_reuse_procs, Prof, 
				"# unconditional reuse-procedures"), 
		write_prof_item( Stream, procs_counted, Prof, 
				"# procedures (total)"),
		io__write_string(Stream, "Exported info:\n"),
		write_prof_item( Stream, exported_procs, Prof, 
				"# exported procedures"),
		write_prof_item( Stream, exported_reuse_procs, Prof, 
				"# exported procedures with reuse"), 
		write_prof_item( Stream, exported_uncond_reuse_procs, Prof, 
			"# exported unconditional procedures with reuse"), 
		io__write_string(Stream, "Alias info:\n"),
		write_prof_item( Stream, aliases, Prof, 
				"# aliases over all the procedures"),
		write_prof_item( Stream, bottom_procs, Prof, 
				"# procedures with alias = bottom"), 
		write_prof_item( Stream, top_procs, Prof, 
				"# procedures with alias = top"), 
		io__write_string( Stream, "About direct reuses:\n"), 
		write_prof_item( Stream, deconstructs, Prof, 
				"# deconstructs"), 
		write_prof_item( Stream, direct_reuses, Prof, 
				"# direct reuses"),
		write_prof_item( Stream, direct_conditions, Prof, 
				"# conditions implied by direct reuses"),
		io__write_string( Stream, "About indirect reuses:\n"),
		write_prof_item( Stream, pred_calls, Prof, 
				"# procedure calls"),
		write_prof_item( Stream, reuse_calls, Prof, 
				"# calls to procedures with reuse"),
		write_prof_item( Stream, no_reuse_calls, Prof, 
				"# failed calls to procedures with reuse"),
		io__close_output(Stream)
	;
		{ IOResult = error(IOError) },
		{ io__error_message(IOError, IOErrorString) }, 
		{ require__error(IOErrorString) }
	).

:- pred write_prof_item( io__output_stream, pred(profiling_info, int), 
			profiling_info, 
			string, io__state, io__state).
:- mode write_prof_item( in, pred(in, out) is det, in, in, di, uo) is det.

write_prof_item( Str, Getter, Prof, Text ) --> 
	{ Getter(Prof,Count) },
	io__format(Str, "%8d  %s\n", [i(Count),s(Text)]).
		
