# Typed Continuations for WebAssembly

## Language Extensions

Based on [typed reference proposal](https://github.com/WebAssembly/function-references/blob/master/proposals/function-references/Overview.md) and [exception handling proposal](https://github.com/WebAssembly/exception-handling/blob/master/proposals/exception-handling/Exceptions.md).


### Types

#### Defined Types

* `cont <typeidx>` is a new form of defined type
  - `(cont $ft) ok` iff `$ft ok` and `$ft = [t1*] -> [t2*]`


### Instructions

* `cont.new <typeidx>` creates a new continuation
  - `cont.new $ct : [(ref null? $ft)] -> [(ref $ct)]`
    - iff `$ct = cont $ft`

* `cont.bind <typidx>` binds a continuation to (partial) arguments
  - `cont.bind $ct : [t3* (ref null? $ct')] -> [(ref $ct)]`
    - iff `$ct = cont $ft`
    - and `$ft = [t1*] -> [t2*]`
    - and `$ct' = cont $ft'`
    - and `$ft' = [t3* t1'*] -> [t2'*]`
    - and `[t1'*] -> [t2'*] <: [t1*] -> [t2*]`

* `suspend <evtidx>` suspends the current continuation
  - `suspend $e : [t1*] -> [t2*]`
    - iff `event $e : [t1*] -> [t2*]`

* `resume (event <evtidx> <labelidx>)*` resumes a continuation
  - `resume (event $e $l)* : [t1* (ref null? $ct)] -> [t2*]`
    - iff `$ct = cont $ft`
    - and `$ft = [t1*] -> [t2*]`
    - and `(event $e : [te1*] -> [te2*])*`
    - and `(label $l : [te1'* (ref null? $ct')])*`
    - and `([te1*] <: [te1'*])*`
    - and `($ct' = cont $ft')*`
    - and `([te2*] -> [t2*] <: $ft')*`

* `resume_throw <evtidx>` aborts a continuation
  - `resume_throw $e : [te* (ref null? $ct)] -> [t2*]`
    - iff `exception $e : [te*]`
    - and `$ct = cont $ft`
    - and `$ft = [t1*] -> [t2*]`

* `barrier <blocktype> <instr>* end` blocks suspension
  - `barrier $l bt instr* end : [t1*] -> [t2*]`
    - iff `bt = [t1*] -> [t2*]`
    - and `instr* : [t1*] -> [t2*]` with labels extended with `[t2*]`


## Reduction Semantics

### Store extensions

* New store component `evts` for allocated events
  - `S ::= {..., evts <evtinst>*}`

* An *event instance* represents an event tag
  - `evtinst ::= {type <evttype>}`

* New store component `conts` for allocated continuations
  - `S ::= {..., conts <cont>?*}`

* A continuation is a context annotated with its hole's arity
  - `cont ::= (E : n)`

* New store component `contrefs` for continuation references
  - `S ::= {..., contrefs <contref>*}`

* A continuation reference is a continuation body address annotated
  with its expected arity (if the expected arity and actual arity do
  not match then the continuation is no longer live and any attempt to
  access it will result in a trap)
  - `contref ::= (cb : n)`


### Administrative instructions

* `(ref.cont ca)` represents a continuation value, where `ca` is a
  *continuation address* indexing into the store's `contrefs`
  component, which in turn indexes into the store's `conts` component
  via a continuation body address
  - `ref.cont ca : [] -> [(ref $ct)]`
    - iff `S.contrefs[ca] = (cb : n) /\ (S.const[cb] = epsilon \/ S.conts[cb] = (E : m))`
    - and `$ct = cont $ft`
    - and `$ft = [t1^n] -> [t2*]`

* `(handle{(<evtaddr> <labelidx>)*}? <instr>* end)` represents an active handler (or a barrier when no handler list is present)
  - `(handle{(ea $l)*}? instr* end) : [t1*] -> [t2*]`
    - iff `instr* : [t1*] -> [t2*]`
    - and `(S.evts[ea].type = [te1*] -> [te2*])*`
    - and `(label $l : [te1'* (ref null? $ct')])*`
    - and `([te1*] <: [te1'*])*`
    - and `($ct' = cont $ft')*`
    - and `([te2*] -> [t2*] <: $ft')*`


### Handler contexts

```
H^ea ::=
  _
  val* H^ea instr*
  label_n{instr*} H^ea end
  frame_n{F} H^ea end
  catch{...} H^ea end
  handle{(ea' $l)*} H^ea end   (iff ea notin ea'*)
```


### Reduction

* `S; F; (ref.null t) (cont.new $ct)  -->  S; F; trap`

* `S; F; (ref.func fa) (cont.new $ct)  -->  S'; F; (ref.cont |S.contrefs|)`
  - iff `S' = S with contrefs += (cb : n), ..., (cb : 0) and conts += (E : n)`
  - and `E = _ (invoke fa)`
  - and `$ct = cont $ft`
  - and `$ft = [t1^n] -> [t2*]`
  - and `cb = |S.conts|`

* `S; F; (ref.null t) (cont.bind $ct)  -->  S; F; trap`

* `S; F; (ref.cont ca) (cont.bind $ct)  -->  S'; F; trap`
  - iff `S.contrefs[ca] = (cb : n)`
  - and `S.const[cb] = epsilon \/ (S.conts[cb] = (E : n') /\ n =/= n')`

* `S; F; v^n (ref.cont ca) (cont.bind $ct)  -->  S'; F; (ref.cont (ca + n))`
  - iff `S.contrefs[ca] = (cb : n')`
  - and `S.conts[cb] = (E : n')`
  - and `$ct = cont $ft`
  - and `$ft = [t1'*] -> [t2'*]`
  - and `n = n' - |t1'*|`
  - and `S' = S with conts[cb] = (E[v^n _] : |t1'*|)`

* `S; F; (ref.null t) (resume (event $e $l)*)  -->  S; F; trap`

* `S; F; (ref.cont ca) (resume (event $e $l)*)  -->  S; F; trap`
  - iff `S.conts[ca] = epsilon`

* `S; F; v^n (ref.cont ca) (resume (event $e $l)*)  -->  S'; F; handle{(ea $l)*} E[v^n] end`
  - iff `S.contrefs[ca] = (cb : n)`
  - and `S.conts[cb] = (E : n)`
  - and `(ea = F.evts[$e])*`
  - and `S' = S with conts[cb] = epsilon`

* `S; F; (ref.null t) (resume_throw $e)  -->  S; F; trap`

* `S; F; (ref.cont ca) (resume_throw $e)  -->  S; F; trap`
  - iff `S.contrefs[ca] = (cb : n)`
  - and `S.const[cb] = epsilon \/ (S.conts[cb] = (E : n') /\ n =/= n')`

* `S; F; v^m (ref.cont ca) (resume_throw $e)  -->  S'; F; E[v^m (throw $e)]`
  - iff `S.contrefs[ca] = (cb : n)`
  - iff `S.conts[cb] = (E : n)`
  - and `S.evts[F.evts[$e]].type = [t1^m] -> [t2*]`
  - and `S' = S with conts[cb] = epsilon`

* `S; F; (barrier bt instr* end)  -->  S; F; handle instr* end`

* `S; F; (handle{(e $l)*}? v* end)  -->  S; F; v*`

* `S; F; (handle H^ea[(suspend $e)] end)  --> S; F; trap`
  - iff `ea = F.evts[$e]`

* `S; F; (handle{(ea1 $l1)* (ea $l) (ea2 $l2)*} H^ea[v^n (suspend $e)] end)  --> S'; F; v^n (ref.cont |S.contrefs|) (br $l)`
  - iff `ea notin ea1*`
  - and `ea = F.evts[$e]`
  - and `S.evts[ea].type = [t1^n] -> [t2^m]`
  - and `S' = S with contrefs += (cb : m), ..., (cb : 0) and conts += (H^ea : m)`
  - and `cb = |S.conts|`
