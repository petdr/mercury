%-----------------------------------------------------------------------------%
% Copyright (C) 1993-2001 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Main authors: conway, fjh.
%
% This file provides a 'tree' data type.
% The code generater uses this to build a tree of instructions and
% then flatten them into a list.
%
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module libs__tree.

%-----------------------------------------------------------------------------%

:- interface.
:- import_module list.
:- type tree(T)		--->	empty
			;	node(T)
			;	tree(tree(T), tree(T)).

:- func tree__flatten(tree(T)) =  list(T).

	% Make a tree from a list of trees.
:- func tree__list(list(tree(T))) = tree(T).

:- pred tree__flatten(tree(T), list(T)).
:- mode tree__flatten(in, out) is det.

:- pred tree__is_empty(tree(T)).
:- mode tree__is_empty(in) is semidet.

:- pred tree__tree_of_lists_is_empty(tree(list(T))).
:- mode tree__tree_of_lists_is_empty(in) is semidet.

:- func tree__map(func(T) = U, tree(T)) = tree(U).

%-----------------------------------------------------------------------------%

:- implementation.

tree__flatten(T) = L :- tree__flatten(T, L).

tree__list([]) = empty.
tree__list([X | Xs]) = tree(X, tree__list(Xs)).

tree__flatten(T, L) :-
	tree__flatten_2(T, [], L).

:- pred tree__flatten_2(tree(T), list(T), list(T)).
:- mode tree__flatten_2(in, in, out) is det.
	% flatten_2(T, L0, L) is true iff L is the list that results from
	% traversing T left-to-right depth-first, and then appending L0.
tree__flatten_2(empty, L, L).
tree__flatten_2(node(T), L, [T|L]).
tree__flatten_2(tree(T1,T2), L0, L) :-
	tree__flatten_2(T2, L0, L1),
	tree__flatten_2(T1, L1, L).

%-----------------------------------------------------------------------------%

tree__is_empty(empty).
tree__is_empty(tree(L, R)) :-
	tree__is_empty(L),
	tree__is_empty(R).

%-----------------------------------------------------------------------------%

tree__tree_of_lists_is_empty(empty).
tree__tree_of_lists_is_empty(node([])).
tree__tree_of_lists_is_empty(tree(L, R)) :-
	tree__tree_of_lists_is_empty(L),
	tree__tree_of_lists_is_empty(R).

%-----------------------------------------------------------------------------%

tree__map(_F, empty) = empty.
tree__map(F, node(T)) = node(F(T)).
tree__map(F, tree(L, R)) = tree(tree__map(F, L), tree__map(F, R)).


%-----------------------------------------------------------------------------%
