(in-package :iolib.examples)

(iolib.sockets:list-network-interfaces)
(iolib.sockets:lookup-interface 3)

(defun multicast-sender ()
  (let ((socket (make-socket :address-family :internet :type :datagram)))
    (setf (socket-option socket :ip-multicast-if)
          (make-address #(192 168 1 169)))
    (unwind-protect
         (loop
           (send-to socket
                    (arnesi:string-to-octets "here is a buffer" :utf-8)
                    :remote-host (make-address #(226 1 1 1))
                    :remote-port 4321)
           (sleep 1)))
    (disconnect socket)))

(defun multicast-receiver ()
  (with-open-socket (socket :address-family :internet :type :datagram)
    (bind-address socket +ipv4-unspecified+ :port 4321)
    (setf (socket-option socket :ip-add-membership)
          (values (make-address #(226 1 1 1))
                  (make-address #(192 168 1 169))))
    (handler-bind ((isys:ewouldblock
                     (lambda (e)
                       (invoke-restart (find-restart 'retry-syscall e) 2))))
      (print (receive-from socket :size 100)))))
