;;;; o11y-report.lisp -- hourly p50/p95 for the LM request o11y stream.
;;;;
;;;; Reads agent/call events from the bus, buckets by hour, reports count,
;;;; cache-hit avg, and p50/p95 for ttft_s and decode_tps.
;;;;
;;;; Usage:  sbcl --noprint --load ~/.quicklisp/setup.lisp --script eval/o11y-report.lisp
;;;;         (all history; db via eventbus:*db-path*, default ./events.db)

(load (merge-pathnames "../src/eventbus.lisp" *load-truename*))

(defpackage :o11y-report
  (:use :cl)
  (:import-from :eventbus #:since))

(in-package :o11y-report)

(defun jnum (h k)
  (let ((v (and (hash-table-p h) (gethash k h)))) (and (numberp v) v)))

(defun percentile (xs p)
  ;; p in (0 1]; nearest-rank on sorted copy. nil-safe.
  (let ((sorted (sort (remove-if #'null (copy-list xs)) #'<)))
    (when sorted
      (let ((idx (max 0 (min (1- (length sorted))
                             (1- (ceiling (* p (length sorted))))))))
        (elt sorted idx)))))

(defun fmt (v &optional (digits 1))
  (if v (format nil "~,vf" digits v) "-"))

(defun main ()
  (let* ((events (since 0 "agent/call"))
         (by-hour (make-hash-table :test 'equal)))
    ;; bucket by ts hour prefix
    (dolist (e events)
      (let ((hour (subseq (getf e :ts) 0 13)))
        (push (getf e :data) (gethash hour by-hour))))
    (format t "~8a ~4a ~10a ~12a ~12a ~12a ~12a~%"
            "hour" "n" "cache%" "ttft_p50" "ttft_p95" "tps_p50" "tps_p95")
    (dolist (hour (sort (loop for k being the hash-keys of by-hour collect k) #'string<))
      (let* ((rows (gethash hour by-hour))
             (ttfts (mapcar (lambda (r) (jnum r "ttft_s")) rows))
             (tpss (mapcar (lambda (r) (jnum r "decode_tps")) rows))
             (caches (remove-if #'null (mapcar (lambda (r) (jnum r "cache_hit_pct")) rows))))
        (format t "~8a ~4d ~10a ~12a ~12a ~12a~12a~%"
                hour (length rows)
                (if caches (fmt (/ (reduce #'+ caches) (length caches))) "-")
                (fmt (percentile ttfts 0.5) 3) (fmt (percentile ttfts 0.95) 3)
                (fmt (percentile tpss 0.5) 1) (fmt (percentile tpss 0.95) 1))))
    (when (zerop (hash-table-count by-hour))
      (format t "(no agent/call events)~%"))))

(main)
