/*
** Copyright (C) 1998-1999 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** mercury_bootstrap.c -
**	Defintions that may be used for bootstrapping purposes.
**
**	Because the runtime is linked as a library, symbols can be
**	safely defined here -- if there is a duplicate symbol
**	generated by the compiler, it will not link this module into
**	the executable.  If the symbol is not generated by the compiler,
**	it will link with the definition in this file.
**	
**	Most of the time this file will	be empty.
**	It should not be used for more than one bootstrapping problem
**	at a time.
*/

#include "mercury_imp.h"

MR_MODULE_STATIC_OR_EXTERN
const struct mercury_data_std_util__type_ctor_layout_type_info_0_struct_bootstrap
{
	TYPE_LAYOUT_FIELDS
} mercury_data_std_util__type_ctor_layout_type_info_0_bootstrap = {
	make_typelayout_for_all_tags(TYPE_CTOR_LAYOUT_CONST_TAG, 
		MR_mkbody(MR_TYPE_CTOR_LAYOUT_TYPEINFO_VALUE))
};

MR_MODULE_STATIC_OR_EXTERN
const struct
mercury_data_std_util__type_ctor_functors_type_info_0_struct_bootstrap {
	Integer f1;
} mercury_data_std_util__type_ctor_functors_type_info_0_bootstrap = {
	MR_TYPE_CTOR_FUNCTORS_SPECIAL
};


Define_extern_entry(mercury____Unify___std_util__type_info_0_0_bootstrap);
Define_extern_entry(mercury____Index___std_util__type_info_0_0_bootstrap);
Define_extern_entry(mercury____Compare___std_util__type_info_0_0_bootstrap);

#if !defined(USE_NONLOCAL_GOTOS) || defined(USE_ASM_LABELS)

const struct MR_TypeCtorInfo_struct
mercury_data_std_util__type_ctor_info_type_info_0 = {
	(Integer) 0,
	ENTRY(mercury____Unify___std_util__type_info_0_0_bootstrap),
	ENTRY(mercury____Index___std_util__type_info_0_0_bootstrap),
	ENTRY(mercury____Compare___std_util__type_info_0_0_bootstrap),
	(Integer) 15,
	(Word *) &mercury_data_std_util__type_ctor_functors_type_info_0_bootstrap,
	(Word *) &mercury_data_std_util__type_ctor_layout_type_info_0_bootstrap,
	string_const("std_util", 8),
	string_const("type_info", 9)
};

#else /* defined(USE_NONLOCAL_GOTOS) && !defined(USE_ASM_LABELS) */

/*
** Can't use ENTRY(...) in initializers, so just don't bother;
** backwards compatibility isn't important for these grades.
*/

#endif


BEGIN_MODULE(unify_univ_module_bootstrap)
	init_entry(mercury____Unify___std_util__type_info_0_0_bootstrap);
	init_entry(mercury____Index___std_util__type_info_0_0_bootstrap);
	init_entry(mercury____Compare___std_util__type_info_0_0_bootstrap);
BEGIN_CODE
Define_entry(mercury____Unify___std_util__type_info_0_0_bootstrap);
{
	/*
	** Unification for type_info.
	**
	** The two inputs are in the registers named by unify_input[12].
	** The success/failure indication should go in unify_output.
	*/
	int	comp;

	save_transient_registers();
	comp = MR_compare_type_info(r1, r2);
	restore_transient_registers();
	r1 = (comp == COMPARE_EQUAL);
	proceed();
}

Define_entry(mercury____Index___std_util__type_info_0_0_bootstrap);
	r1 = -1;
	proceed();

Define_entry(mercury____Compare___std_util__type_info_0_0_bootstrap);
{
	/*
	** Comparison for type_info:
	**
	** The two inputs are in the registers named by compare_input[12].
	** The result should go in compare_output.
	*/
	int	comp;

	save_transient_registers();
	comp = MR_compare_type_info(r1, r2);
	restore_transient_registers();
	r1 = comp;
	proceed();
}

END_MODULE

/* Ensure that the initialization code for the above module gets run. */
/*
INIT sys_init_unify_univ_module_bootstrap
*/
extern ModuleFunc unify_univ_module_bootstrap;
void sys_init_unify_univ_module_bootstrap(void); /* suppress gcc -Wmissing-decl warning */
void sys_init_unify_univ_module_bootstrap(void) {
	unify_univ_module_bootstrap();
}

void call_engine(Code *entry_point); /* suppress gcc -Wmissing-decl warning */
void call_engine(Code *entry_point) {
	(void) MR_call_engine(entry_point, FALSE);
}
