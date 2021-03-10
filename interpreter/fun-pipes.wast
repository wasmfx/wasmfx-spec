;; Simple pipes example (functional version)
(module $pipes
  (type $producer (func (result i32)))
  (type $consumer (func (param i32) (result i32)))
  (type $pcont (cont $producer))
  (type $ccont (cont $consumer))

  (event $send (export "send") (param i32))
  (event $receive (export "receive") (result i32))

  (elem declare func $piper $copiper)

  (func $piper (param $n i32) (param $p (ref $pcont)) (param $c (ref $ccont))
     (block $on-receive (result (ref $ccont))
        (resume (event $receive $on-receive) (local.get $n) (local.get $c))
        (return)
     ) ;; receive
     (local.set $c)
     (return_call_ref (local.get $c) (local.get $p) (ref.func $copiper))
  )

  (func $copiper (param $c (ref $ccont)) (param $p (ref $pcont))
     (local $n i32)
     (block $on-send (result i32 (ref $pcont))
        (resume (event $send $on-send) (local.get $p))
        (return)
     ) ;; send
     (local.set $p)
     (local.set $n)
     (return_call_ref (local.get $n) (local.get $p) (local.get $c) (ref.func $piper))
  )

  (func $pipe (export "pipe") (param $p (ref $producer)) (param $c (ref $consumer))
     (call $piper (i32.const -1) (cont.new (type $pcont) (local.get $p)) (cont.new (type $ccont) (local.get $c)))
  )
)

(register "pipes")

(module
  (type $producer (func (result i32)))
  (type $consumer (func (param i32) (result i32)))

  (event $send (import "pipes" "send") (param i32))
  (event $receive (import "pipes" "receive") (result i32))

  (func $pipe (import "pipes" "pipe") (param $p (ref $producer)) (param $c (ref $consumer)))

  (func $log (import "spectest" "print_i32") (param i32))

  (elem declare func $nats $sum)

  ;; send n, n+1, ...
  (func $nats (param $n i32) (result i32)
     (loop $l
       (call $log (i32.const -1))
       (call $log (local.get $n))
       (suspend $send (local.get $n))
       (local.set $n (i32.add (local.get $n) (i32.const 1)))
       (br $l)
     )
     (unreachable)
  )

  ;; receive 10 nats and return their sum
  (func $sum (param $dummy i32) (result i32)
     (local $i i32)
     (local $a i32)
     (local.set $i (i32.const 10))
     (local.set $a (i32.const 0))
     (loop $l
       (local.set $a (i32.add (local.get $a) (suspend $receive)))
       (call $log (i32.const -2))
       (call $log (local.get $a))
       (local.set $i (i32.sub (local.get $i) (i32.const 1)))
       (br_if $l (i32.ne (local.get $i) (i32.const 0)))
     )
     (return (local.get $a))
  )

  (func (export "run") (param $n i32)
     (call $pipe (func.bind (type $producer) (local.get $n) (ref.func $nats)) (ref.func $sum))
 )
)

(assert_return (invoke "run" (i32.const 0)))
