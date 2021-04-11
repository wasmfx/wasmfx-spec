;; Actors via lightweight threads - functional version

;; actor interface
(module $actor
  (type $func (func))
  (type $cont (cont $func))

  (event $self (export "self") (result i32))
  (event $spawn (export "spawn") (param (ref $cont)) (result i32))
  (event $send (export "send") (param i32 i32))
  (event $recv (export "recv") (result i32))
)
(register "actor")

;; a simple example - pass a message through a chain of actors
(module $chain
  (type $func (func))
  (type $cont (cont $func))

  (type $i-func (func (param i32)))
  (type $i-cont (cont $i-func))

  (event $self (import "actor" "self") (result i32))
  (event $spawn (import "actor" "spawn") (param (ref $cont)) (result i32))
  (event $send (import "actor" "send") (param i32 i32))
  (event $recv (import "actor" "recv") (result i32))

  (elem declare func $next)

  (func $log (import "spectest" "print_i32") (param i32))

  (func $next (param $p i32)
    (local $s i32)
    (local.set $s (suspend $recv))
    (call $log (i32.const -1))
    (suspend $send (local.get $s) (local.get $p))
  )

  (func $spawnMany (param $p i32) (param $n i32)
    (if (i32.eqz (local.get $n))
      (then (suspend $send (i32.const 42) (local.get $p))
            (return))
      (else (return_call $spawnMany (suspend $spawn (cont.bind (type $cont) (local.get $p) (cont.new (type $i-cont) (ref.func $next))))
                                    (i32.sub (local.get $n) (i32.const 1))))

    )
  )

  ;; send the message 42 through a chain of n actors
  (func $chain (export "chain") (param $n i32)
    (local $s i32)
    (call $spawnMany (suspend $self) (local.get $n))
    (local.set $s (suspend $recv))
    (call $log (local.get $s))
  )
)
(register "chain")

;; interface to lightweight threads
(module $lwt
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (export "yield"))
  (event $fork (export "fork") (param (ref $cont)))
)
(register "lwt")

;; queue of threads
(module $queue
  (type $func (func))
  (type $cont (cont $func))

  ;; Table as simple queue (keeping it simple, no ring buffer)
  (table $queue 0 (ref null $cont))
  (global $qdelta i32 (i32.const 10))
  (global $qback (mut i32) (i32.const 0))
  (global $qfront (mut i32) (i32.const 0))

  (func $queue-empty (export "queue-empty") (result i32)
    (i32.eq (global.get $qfront) (global.get $qback))
  )

  (func $dequeue (export "dequeue") (result (ref null $cont))
    (local $i i32)
    (if (call $queue-empty)
      (then (return (ref.null $cont)))
    )
    (local.set $i (global.get $qfront))
    (global.set $qfront (i32.add (local.get $i) (i32.const 1)))
    (table.get $queue (local.get $i))
  )

  (func $enqueue (export "enqueue") (param $k (ref $cont))
    ;; Check if queue is full
    (if (i32.eq (global.get $qback) (table.size $queue))
      (then
        ;; Check if there is enough space in the front to compact
        (if (i32.lt_u (global.get $qfront) (global.get $qdelta))
          (then
            ;; Space is below threshold, grow table instead
            (drop (table.grow $queue (ref.null $cont) (global.get $qdelta)))
          )
          (else
            ;; Enough space, move entries up to head of table
            (global.set $qback (i32.sub (global.get $qback) (global.get $qfront)))
            (table.copy $queue $queue
              (i32.const 0)         ;; dest = new front = 0
              (global.get $qfront)  ;; src = old front
              (global.get $qback)   ;; len = new back = old back - old front
            )
            (table.fill $queue      ;; null out old entries to avoid leaks
              (global.get $qback)   ;; start = new back
              (ref.null $cont)      ;; init value
              (global.get $qfront)  ;; len = old front = old front - new front
            )
            (global.set $qfront (i32.const 0))
          )
        )
      )
    )
    (table.set $queue (global.get $qback) (local.get $k))
    (global.set $qback (i32.add (global.get $qback) (i32.const 1)))
  )
)
(register "queue")

;; simple scheduler
(module $scheduler
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $cont)))

  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))

  (func $scheduler (export "scheduler") (param $main (ref $func))
    (call $enqueue (cont.new (type $cont) (local.get $main)))
    (loop $l
      (if (call $queue-empty) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (event $yield $on_yield) (event $fork $on_fork)
            (call $dequeue)
          )
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (call $enqueue) ;; current thread
        (call $enqueue) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue) ;; current thread
      (br $l)
    )
  )
)
(register "scheduler")

(module $mailboxes
  ;; Stupid implementation of mailboxes that raises an exception if
  ;; there are too many mailboxes or if more than one messages is sent
  ;; to any given mailbox.
  ;;
  ;; Sufficient for the simple chain example.

  ;; -1 means empty

  (exception $too-many-mailboxes)
  (exception $too-many-messages)

  (memory 1)

  (global $msize (mut i32) (i32.const 0))
  (global $mmax i32 (i32.const 1024)) ;; maximum number of mailboxes

  (func $init (export "init")
     (memory.fill (i32.const 0) (i32.const -1) (i32.mul (global.get $mmax) (i32.const 4)))
  )

  (func $empty-mb (export "empty-mb") (param $mb i32) (result i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (i32.eq (i32.load (local.get $offset)) (i32.const -1))
  )

  (func $new-mb (export "new-mb") (result i32)
     (local $mb i32)

     (if (i32.ge_u (global.get $msize) (global.get $mmax))
         (then (throw $too-many-mailboxes))
     )

     (local.set $mb (global.get $msize))
     (global.set $msize (i32.add (global.get $msize) (i32.const 1)))
     (return (local.get $mb))
  )

  (func $send-to-mb (export "send-to-mb") (param $v i32) (param $mb i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (if (call $empty-mb (local.get $mb))
      (then (i32.store (local.get $offset) (local.get $v)))
      (else (throw $too-many-messages))
    )
  )

  (func $recv-from-mb (export "recv-from-mb") (param $mb i32) (result i32)
    (local $v i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (local.set $v (i32.load (local.get $offset)))
    (i32.store (local.get $offset) (i32.const -1))
    (local.get $v)
  )
)
(register "mailboxes")

;; actors via lightweight threads
(module $actor-as-lwt
  (type $func (func))
  (type $cont (cont $func))

  (type $i-func (func (param i32)))
  (type $i-cont (cont $i-func))

  (type $icont-func (func (param i32 (ref $cont))))
  (type $icont-cont (cont $icont-func))

  (func $log (import "spectest" "print_i32") (param i32))

  ;; lwt interface
  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $cont)))

  ;; mailbox interface
  (func $init (import "mailboxes" "init"))
  (func $empty-mb (import "mailboxes" "empty-mb") (param $mb i32) (result i32))
  (func $new-mb (import "mailboxes" "new-mb") (result i32))
  (func $send-to-mb (import "mailboxes" "send-to-mb") (param $v i32) (param $mb i32))
  (func $recv-from-mb (import "mailboxes" "recv-from-mb") (param $mb i32) (result i32))

  ;; actor interface
  (event $self (import "actor" "self") (result i32))
  (event $spawn (import "actor" "spawn") (param (ref $cont)) (result i32))
  (event $send (import "actor" "send") (param i32 i32))
  (event $recv (import "actor" "recv") (result i32))

  (elem declare func $act-nullary $act-res)

  ;; resume with $ik applied to $res
  (func $act-res (param $mine i32) (param $res i32) (param $ik (ref $i-cont))
    (block $on_self (result (ref $i-cont))
      (block $on_spawn (result (ref $cont) (ref $i-cont))
        (block $on_send (result i32 i32 (ref $cont))
          (block $on_recv (result (ref $i-cont))
             ;; this should really be a tail call to the continuation
             ;; do we need a 'return_resume' operator?
             (resume (event $self $on_self)
                     (event $spawn $on_spawn)
                     (event $send $on_send)
                     (event $recv $on_recv)
                     (local.get $res) (local.get $ik)
             )
             (return)
          ) ;;   $on_recv (result (ref $i-cont))
          (let (local $ik (ref $i-cont))
            ;; block this thread until the mailbox is non-empty
            (loop $l
              (if (call $empty-mb (local.get $mine))
                  (then (suspend $yield)
                        (br $l))
              )
            )
            (call $recv-from-mb (local.get $mine))
            (local.set $res)
            (return_call $act-res (local.get $mine) (local.get $res) (local.get $ik)))
          (unreachable)
        ) ;;   $on_send (result i32 i32 (ref $cont))
        (let (param i32 i32) (local $k (ref $cont))
          (call $send-to-mb)
          (return_call $act-nullary (local.get $mine) (local.get $k)))
        (unreachable)
      ) ;;   $on_spawn (result (ref $cont) (ref $i-cont))
      (let (local $you (ref $cont)) (local $ik (ref $i-cont))
        (call $new-mb)
        (let (local $yours i32)
          (suspend $fork (cont.bind (type $cont)
                                    (local.get $yours)
                                    (local.get $you)
                                    (cont.new (type $icont-cont) (ref.func $act-nullary))))
          (return_call $act-res (local.get $mine) (local.get $yours) (local.get $ik))
        )
      )
      (unreachable)
    ) ;;   $on_self (result (ref $i-cont))
    (let (local $ik (ref $i-cont))
      (return_call $act-res (local.get $mine) (local.get $mine) (local.get $ik))
    )
    (unreachable)
  )

  ;; resume with nullary continuation
  (func $act-nullary (param $mine i32) (param $k (ref $cont))
    (local $res i32)
    (block $on_self (result (ref $i-cont))
      (block $on_spawn (result (ref $cont) (ref $i-cont))
        (block $on_send (result i32 i32 (ref $cont))
          (block $on_recv (result (ref $i-cont))
             ;; this should really be a tail call to the continuation
             ;; do we need a 'return_resume' operator?
             (resume (event $self $on_self)
                     (event $spawn $on_spawn)
                     (event $send $on_send)
                     (event $recv $on_recv)
                     (local.get $k)
             )
             (return)
          ) ;;   $on_recv (result (ref $i-cont))
          (let (local $ik (ref $i-cont))
            ;; block this thread until the mailbox is non-empty
            (loop $l
              (if (call $empty-mb (local.get $mine))
                  (then (suspend $yield)
                        (br $l))
              )
            )
            (call $recv-from-mb (local.get $mine))
            (local.set $res)
            (return_call $act-res (local.get $mine) (local.get $res) (local.get $ik)))
          (unreachable)
        ) ;;   $on_send (result i32 i32 (ref $cont))
        (let (param i32 i32) (local $k (ref $cont))
          (call $send-to-mb)
          (return_call $act-nullary (local.get $mine) (local.get $k)))
        (unreachable)
      ) ;;   $on_spawn (result (ref $cont) (ref $i-cont))
      (let (local $you (ref $cont)) (local $ik (ref $i-cont))
        (call $new-mb)
        (let (local $yours i32)
          (suspend $fork (cont.bind (type $cont)
                                    (local.get $yours)
                                    (local.get $you)
                                    (cont.new (type $icont-cont) (ref.func $act-nullary))))
          (return_call $act-res (local.get $mine) (local.get $yours) (local.get $ik))
        )
      )
      (unreachable)
    ) ;;   $on_self (result (ref $i-cont))
    (let (local $ik (ref $i-cont))
      (return_call $act-res (local.get $mine) (local.get $mine) (local.get $ik))
    )
    (unreachable)
  )

  (func $act (export "act") (param $f (ref $func))
    (call $init)
    (call $act-nullary (call $new-mb) (cont.new (type $cont) (local.get $f)))
  )
)
(register "actor-as-lwt")

;; composing the actor and scheduler handlers together
(module $actor-scheduler
  (type $proc (func))
  (type $procproc (func (param (ref $proc))))

  (elem declare func $act $scheduler $comp)

  (func $act (import "actor-as-lwt" "act") (param $f (ref $proc)))
  (func $scheduler (import "scheduler" "scheduler") (param $main (ref $proc)))

  (func $comp (param $h (ref $procproc)) (param $g (ref $procproc)) (param $f (ref $proc))
    (call_ref (func.bind (type $proc) (local.get $f) (local.get $g)) (local.get $h))
  )

  (func $compose (param $h (ref $procproc)) (param $g (ref $procproc)) (result (ref $procproc))
    (func.bind (type $procproc) (local.get $h) (local.get $g) (ref.func $comp))
  )

  (func $run-actor (export "run-actor") (param $f (ref $proc))
    (call_ref (local.get $f) (call $compose (ref.func $scheduler) (ref.func $act)))
  )
)
(register "actor-scheduler")

(module
  (type $proc (func))

  (elem declare func $chain)

  (func $run-actor (import "actor-scheduler" "run-actor") (param $f (ref $proc)))
  (func $chain (import "chain" "chain") (param $n i32))

  (func $run-chain (export "run-chain") (param $n i32)
    (call $run-actor (func.bind (type $proc) (local.get $n) (ref.func $chain)))
  )
)

(invoke "run-chain" (i32.const 64))
