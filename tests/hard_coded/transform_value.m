% Test the map.transform_value predicate.
%

:- module transform_value.

:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module map, int, svmap, list, assoc_list, rbtree.

main(!IO) :-
	some [!M] (
		!:M = map.init,
		svmap.set(1, 1, !M),
		svmap.set(2, 1, !M),
		svmap.set(3, 1, !M),
		svmap.set(4, 1, !M),
		svmap.set(5, 1, !M),
		svmap.set(6, 1, !M),
		svmap.set(7, 1, !M),
		svmap.set(8, 1, !M),
		M0 = !.M,
		( map.transform_value(add1, 2, !.M, M1) ->
			io.write_int(M1 ^ det_elem(2), !IO)
		;
			io.write_string("key not found", !IO)
		),
		io.nl(!IO),
		( map.transform_value(add1, 9, !.M, M2) ->
			io.write_int(M2 ^ det_elem(9), !IO)
		;
			io.write_string("key not found", !IO)
		),
		io.nl(!IO),
		map.det_transform_value(add1, 3, !M),
		io.write_int(!.M ^ det_elem(3), !IO),
		io.nl(!IO),
		M3 = map.det_transform_value(f, 7, !.M),
		io.write_int(M3 ^ det_elem(7), !IO),
		io.nl(!IO),
		list.foldl(map.det_transform_value(add1), 
			[1, 2, 3, 4, 5, 6, 7, 8], M0, M4),
		A`with_type`assoc_list(int, int) = map.to_assoc_list(M4),
		io.write(A, !IO),
		io.nl(!IO),
		RB0 = rbtree.init,
		rbtree.set(RB0, 1, 1, RB1),
		rbtree.set(RB1, 2, 1, RB2),
		(
			rbtree.transform_value(add1, 1, RB2, RB3),
			rbtree.transform_value(add1, 2, RB3, RB4)
		->
			A2`with_type`assoc_list(int, int) = 
				rbtree.rbtree_to_assoc_list(RB4),
			io.write(A2, !IO)
		;
			io.write_string("key not found", !IO)
		),
		io.nl(!IO)
	).
		
:- pred add1(int::in, int::out) is det.

add1(X, X+1).

:- func f(int) = int.

f(X) = X+1.
