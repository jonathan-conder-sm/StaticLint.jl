function infer_type(binding::Binding, scope, state)
    if binding isa Binding
        binding.type !== nothing && return
        if binding.val isa EXPR && CSTParser.defines_module(binding.val)
            binding.type = CoreTypes.Module
        elseif binding.val isa EXPR && CSTParser.defines_function(binding.val)
            binding.type = CoreTypes.Function
        elseif binding.val isa EXPR && CSTParser.defines_datatype(binding.val)
            binding.type = CoreTypes.DataType
        elseif binding.val isa EXPR
            if isassignment(binding.val)
                if CSTParser.is_func_call(binding.val[1])
                    binding.type = CoreTypes.Function
                elseif CSTParser.is_func_call(binding.val[3])
                    callname = CSTParser.get_name(binding.val[3])
                    if isidentifier(callname)
                        resolve_ref(callname, scope, state)
                        if hasref(callname)
                            rb = get_root_method(refof(callname), state.server)
                            if (rb isa Binding && (rb.type == CoreTypes.DataType || rb.val isa SymbolServer.DataTypeStore)) || rb isa SymbolServer.DataTypeStore
                                binding.type = rb
                            end
                        end
                    end
                elseif headof(binding.val[3]) === :INTEGER
                    binding.type = CoreTypes.Int
                elseif headof(binding.val[3]) === :FLOAT
                    binding.type = CoreTypes.Float64
                elseif CSTParser.isstringliteral(binding.val[3])
                    binding.type = CoreTypes.String
                elseif isidentifier(binding.val[3]) && refof(binding.val[3]) isa Binding
                    binding.type = refof(binding.val[3]).type
                end
            elseif binding.val.head isa EXPR && valof(binding.val.head) == "::"
                t = binding.val.args[2]
                if isidentifier(t)
                    resolve_ref(t, scope, state)
                end
                if iscurly(t)
                    t = t.args[1]
                    resolve_ref(t, scope, state)
                end
                if CSTParser.is_getfield_w_quotenode(t)
                    resolve_getfield(t, scope, state)
                    t = t.args[2].args[1]
                end
                if refof(t) isa Binding
                    rb = get_root_method(refof(t), state.server)
                    if rb isa Binding && rb.type == CoreTypes.DataType
                        binding.type = rb
                    else
                        binding.type = refof(t)
                    end
                elseif refof(t) isa SymbolServer.DataTypeStore
                    binding.type = refof(t)
                end
            end
        end
    end
end

# Work out what type a bound variable has by functions that are called on it.
function infer_type_by_use(b::Binding, server)
    b.type !== nothing && return # b already has a type
    possibletypes = []
    visitedmethods = []
    for ref in b.refs
        new_possibles = []
        ref isa EXPR || continue # skip non-EXPR (i.e. used for handling of globals)
        check_ref_against_calls(ref, visitedmethods, new_possibles, server)

        if isempty(possibletypes)
            possibletypes = new_possibles
        elseif !isempty(new_possibles)
            possibletypes = intersect(possibletypes, new_possibles)
            if isempty(possibletypes)
                return
            end
        end
    end
    # Only do something if we're left with a singleton set at the end.
    if length(possibletypes) == 1
        type = first(possibletypes)
    
        if type isa Binding
            b.type = type
        elseif type isa SymbolServer.DataTypeStore
            b.type = type
        elseif type isa SymbolServer.VarRef
            b.type = SymbolServer._lookup(type, getsymbolserver(server)) # could be nothing
        elseif type isa SymbolServer.FakeTypeName && isempty(type.parameters)
            b.type = SymbolServer._lookup(type.name, getsymbolserver(server)) # could be nothing
        end
    end
end

function check_ref_against_calls(x, visitedmethods, new_possibles, server)
    if is_arg_of_resolved_call(x)
        sig = parentof(x)
        # x is argument of function call (func) and we know what that function is
        if CSTParser.isidentifier(sig.args[1])
            func = refof(sig.args[1])
        else
            func = refof(sig.args[1].args[2].args[1])
        end
        # make sure we've got the last binding for func
        if func isa Binding
            func = get_last_method(func, server)
        end
        # what slot does ref sit in?
        argi = get_arg_position_in_call(sig, x)
        tls = retrieve_toplevel_scope(x)
        while (func isa Binding && func.type == CoreTypes.Function) || func isa SymbolServer.SymStore
            !(func in visitedmethods) ? push!(visitedmethods, func) : return # check whether we've been here before
            if func isa Binding
                get_arg_type_at_position(func, argi, new_possibles)
                func = func.prev
            else
                tls === nothing && return
                iterate_over_ss_methods(func, tls, server, m->(get_arg_type_at_position(m, argi, new_possibles);false))
                return
            end
        end
    end
end

function is_arg_of_resolved_call(x::EXPR) 
    parentof(x) isa EXPR && headof(parentof(x)) === :call && # check we're in a call signature
    (caller = parentof(x).args[1]) !== x && # and that x is not the caller
    (hasref(caller) || (is_getfield(caller) && headof(caller.args[2]) === :quotenode && hasref(caller.args[2].args[1])))
end

function get_arg_position_in_call(sig::EXPR, arg)
    for i in 1:length(sig.args)
        sig.args[i] == arg && return i
    end
end

function get_arg_type_at_position(b::Binding, argi, types)
    if b.val isa EXPR
        sig = CSTParser.get_sig(b.val)
        if sig !== nothing && 
            sig.args !== nothing && argi <= length(sig.args) &&
            hasbinding(sig.args[argi]) &&
            (argb = bindingof(sig.args[argi]); argb isa Binding && argb.type !== nothing) && 
            !(argb.type in types)
            push!(types, argb.type)
            return
        end
    elseif b.val isa SymbolServer.DataTypeStore || b.val isa SymbolServer.FunctionStore
        for m in b.val.methods
            get_arg_type_at_position(m, argi, types)
        end
    end
    return
end

function get_arg_type_at_position(m::SymbolServer.MethodStore, argi, types)
    if length(m.sig) >= argi && m.sig[argi][2] != SymbolServer.VarRef(SymbolServer.VarRef(nothing, :Core), :Any) && !(m.sig[argi][2] in types)
        push!(types, m.sig[argi][2])
    end
end

function get_last_method(b::Binding, server, visited_bindings = Binding[])
    if b.next === nothing || b == b.next || !(b.next isa Binding) || b in visited_bindings
        return b
    end
    push!(visited_bindings, b)
    if b.type == b.next.type == CoreTypes.Function
        return get_last_method(b.next, server, visited_bindings)
    else
        return b
    end
end
