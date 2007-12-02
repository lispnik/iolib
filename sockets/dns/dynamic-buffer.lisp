;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Indent-tabs-mode: NIL -*-
;;;
;;; dynamic-buffer.lisp --- Read/write adjustable buffer.
;;;
;;; Copyright (C) 2006-2007, Stelian Ionescu  <sionescu@common-lisp.net>
;;;
;;; This code is free software; you can redistribute it and/or
;;; modify it under the terms of the version 2.1 of
;;; the GNU Lesser General Public License as published by
;;; the Free Software Foundation, as clarified by the
;;; preamble found here:
;;;     http://opensource.franz.com/preamble.html
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General
;;; Public License along with this library; if not, write to the
;;; Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
;;; Boston, MA 02110-1301, USA

(in-package :net.sockets)

(defclass dynamic-buffer ()
  ((sequence     :initform nil  :initarg :sequence
                 :accessor sequence-of)
   (read-cursor  :initform 0    :accessor read-cursor-of)
   (write-cursor :initform 0    :accessor write-cursor-of)
   (size         :initarg :size :accessor size-of))
  (:default-initargs :size +dns-datagram-size+))

(defmethod initialize-instance :after ((buffer dynamic-buffer) &key)
  (with-accessors ((seq sequence-of) (size size-of)
                   (wcursor write-cursor-of)) buffer
    (check-type seq (or null ub8-vector))
    (cond
      ((null seq) (setf seq (make-array size :element-type 'ub8
                                        :adjustable t :fill-pointer 0)))
      (t (setf size (length seq)
               wcursor (length seq)
               seq (make-array size :element-type 'ub8
                               :adjustable t :fill-pointer size
                               :initial-contents seq))))))

(defun ub16-to-vector (value)
  (vector (ldb (byte 8 8) value)
          (ldb (byte 8 0) value)))

(defun ub32-to-vector (value)
  (vector (ldb (byte 8 32) value)
          (ldb (byte 8 16) value)
          (ldb (byte 8 8) value)
          (ldb (byte 8 0) value)))

(defvar *buffer-growth-margin* 50)

(defun maybe-grow-buffer (buffer vector)
  (declare (type dynamic-buffer buffer)
           (type array vector))
  (with-accessors ((seq sequence-of) (wcursor write-cursor-of)
                   (size size-of)) buffer
    (let* ((vlen (length vector))
           (newsize (+ size vlen *buffer-growth-margin*)))
      (when (< size (+ wcursor vlen))
        (setf seq (adjust-array seq newsize))
        (setf size newsize))))
  (values buffer))

(defgeneric write-vector (buffer vector)
  (:method ((buffer dynamic-buffer) (vector array))
    (maybe-grow-buffer buffer vector)
    (with-accessors ((seq sequence-of) (wcursor write-cursor-of)) buffer
      (let ((vlen (length vector)))
        (incf (fill-pointer seq) vlen)
        (replace seq vector :start1 wcursor)
        (incf wcursor vlen)))
    (values buffer)))

(defgeneric write-ub8 (buffer vector)
  (:method ((buffer dynamic-buffer) (value integer))
    (write-vector buffer (vector value))))

(defgeneric write-ub16 (buffer vector)
  (:method ((buffer dynamic-buffer) (value integer))
    (write-vector buffer (ub16-to-vector value))))

(defgeneric write-ub32 (buffer vector)
  (:method ((buffer dynamic-buffer)
            (value integer))
    (write-vector buffer (ub32-to-vector value))))

(defmacro with-dynamic-buffer ((var &key size) &body body)
  `(let ((,var ,(if size
                    `(make-instance 'dynamic-buffer
                                    :size ,size)
                    `(make-instance 'dynamic-buffer))))
     ,@body
     ,var))

(define-condition dynamic-buffer-input-error (error)
  ((buffer :initform (error "Must supply buffer")
           :initarg :buffer :reader buffer-of)))

(define-condition input-buffer-eof (dynamic-buffer-input-error)
  ((bytes-requested :initarg :requested :reader bytes-requested)
   (bytes-remaining :initarg :remaining :reader bytes-remaining))
  (:documentation
   "Signals that an INPUT-BUFFER contains less unread bytes than requested."))

(define-condition input-buffer-index-out-of-bounds (dynamic-buffer-input-error) ()
  (:documentation
   "Signals that DYNAMIC-BUFFER-SEEK-READ-CURSOR on an INPUT-BUFFER was passed an
invalid offset."))

(defgeneric dynamic-buffer-seek-read-cursor (buffer place &optional offset)
  (:method ((buffer dynamic-buffer) place &optional offset)
    (check-type place (member :start :end :offset))
    (when (eq place :offset)
      (check-type offset unsigned-byte "a non-negative value"))
    (with-accessors ((seq sequence-of) (rcursor read-cursor-of)
                     (size size-of)) buffer
      (case place
        (:start (setf rcursor 0))
        (:end   (setf rcursor size))
        (:offset
         (if (>= offset size)
             (error 'input-buffer-index-out-of-bounds :buffer buffer)
             (setf rcursor offset)))))))

(defgeneric unread-bytes (buffer)
  (:method ((buffer dynamic-buffer))
    (- (write-cursor-of buffer) (read-cursor-of buffer))))

(defgeneric check-if-enough-bytes (buffer length)
  (:method ((buffer dynamic-buffer) length)
    (check-type length unsigned-byte)
    (when (< (unread-bytes buffer) length)
      (error 'input-buffer-eof
             :buffer buffer
             :requested length
             :remaining (unread-bytes buffer)))))

(defmacro read-ub-be (vector position &optional (length 1))
  `(+ ,@(loop :for i :below length
              :collect `(ash (aref ,vector (+ ,position ,i))
                             ,(* (- length i 1) 8)))))

(defun read-ub16-from-vector (vector position)
  (read-ub-be vector position 2))

(defun read-ub32-from-vector (vector position)
  (read-ub-be vector position 4))

(defgeneric read-vector (buffer length)
  (:method ((buffer dynamic-buffer) length)
    (let* ((bytes-to-read (min (unread-bytes buffer) length))
           (newvector (make-array bytes-to-read :element-type 'ub8)))
      (with-accessors ((seq sequence-of) (pos read-cursor-of)) buffer
        (replace newvector seq :start2 pos)
        (incf pos bytes-to-read))
      (values newvector))))

(defgeneric read-ub8 (buffer)
  (:method ((buffer dynamic-buffer))
    (check-if-enough-bytes buffer 1)
    (prog1
        (aref (sequence-of buffer) (read-cursor-of buffer))
      (incf (read-cursor-of buffer)))))

(defgeneric read-ub16 (buffer)
  (:method ((buffer dynamic-buffer))
    (check-if-enough-bytes buffer 2)
    (prog1
        (read-ub16-from-vector (sequence-of buffer) (read-cursor-of buffer))
      (incf (read-cursor-of buffer) 2))))

(defgeneric read-ub32 (buffer)
  (:method ((buffer dynamic-buffer))
    (check-if-enough-bytes buffer 4)
    (prog1
        (read-ub32-from-vector (sequence-of buffer) (read-cursor-of buffer))
      (incf (read-cursor-of buffer) 4))))