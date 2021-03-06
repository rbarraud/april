;;; aplesque.lisp

(in-package #:aplesque)

(defun is-singleton (value)
  (let ((adims (dims value)))
    (and (= 1 (first adims))
	 (= 1 (length adims)))))

(defun scale-array (singleton to-match &optional axis)
  "Scale up a 1-element array to fill the dimensions of the given array."
  (let ((match-dims (dims to-match)))
    (make-array (if axis
		    (loop for this-dim from 0 to (1- (length match-dims))
		       collect (if (= this-dim axis)
				   1 (nth this-dim match-dims)))
		    match-dims)
		:initial-element (aref singleton 0))))

(defun array-promote (array)
  "Promote an array to the next rank. The existing content will occupy 1 unit of the new dimension."
  (make-array (cons 1 (dims array))
	      :initial-contents (list (array-to-list array))))

(defun array-to-list (array)
  "Convert array to list."
  (if (not (arrayp array))
      (list array)
      (let* ((dimensions (dims array))
	     (depth (1- (length dimensions)))
	     (indices (make-list (1+ depth) :initial-element 0)))
	(labels ((recurse (n)
		   (loop for j below (nth n dimensions)
		      do (setf (nth n indices) j)
		      collect (if (= n depth)
				  (apply #'aref array indices)
				  (recurse (1+ n))))))
	  (recurse 0)))))

(defun array-compare (item1 item2)
  "Perform a deep comparison of two APL arrays, which may be multidimensional or nested."
  (if (and (not (arrayp item1))
	   (not (arrayp item2)))
      (or (and (numberp item1)
	       (numberp item2)
	       (= item1 item2))
	  (and (characterp item1)
	       (characterp item2)
	       (char= item1 item2)))
      (if (and (= (rank item1)
		  (rank item2))
	       (let ((dims1 (dims item1))
		     (dims2 (dims item2)))
		 (loop for d from 0 to (1- (length dims1))
		    always (= (nth d dims1)
			      (nth d dims2)))))
	  (let ((match t))
	    (run-dim item1 (lambda (item coords)
			     (let ((alternate (apply #'aref (cons item2 coords))))
			       (setq match (and match (or (and (arrayp item)
							       (arrayp alternate)
							       (array-compare item alternate))
							  (and (numberp item)
							       (numberp alternate)
							       (= item alternate))
							  (and (characterp item)
							       (characterp alternate)
							       (char= item alternate))))))))
	    match))))

(defun array-depth (array &optional layer)
  "Find the maximum depth of nested arrays within an array."
  (let* ((layer (if layer layer 1))
	 (new-layer layer))
    (aops:each (lambda (item)
		 (if (arrayp item)
		     (setq new-layer (max new-layer (array-depth item (1+ layer))))))
	       array)
    new-layer))

(defun swap! (v i j)
  (let ((tt (aref v i)))
    (setf (aref v i)
	  (aref v j))
    (setf (aref v j) tt)))

(defun reverse! (v lo hi)
  (when (< lo hi)
    (swap! v lo hi)
    (reverse! v (+ lo 1) (- hi 1))))

(defun rotate! (n v)
  (let* ((len (length v))
	 (n (mod n len)))
    (reverse! v 0 (- n 1))
    (reverse! v n (- len 1))
    (reverse! v 0 (- len 1))))

(defun make-rotator (&optional degrees)
  "Create a function to rotate an array by a given number of degrees, or otherwise reverse it."
  (lambda (vector)
    (if degrees (rotate! degrees vector)
	(reverse! vector 0 (1- (length vector))))))

(defun rotate-left (n l)
  (append (nthcdr n l) (butlast l (- (length l) n))))

(defun rotate-right (n l)
  (rotate-left (- (length l) n) l))

(defun multidim-slice (array dimensions &key (inverse nil) (fill-with 0))
  "Take a slice of an array in multiple dimensions."
  (if (= 1 (length dimensions))
      (if (and inverse (> 0 (first dimensions)))
	  ;; in the case of a negative drop operation, partition the array from 0
	  ;; to the length minus the drop number
	  (aops:partition array 0 (+ (first dimensions)
				     (first (dims array))))
	  (apply #'aops:stack
		 (append (list 0 (aops:partition array (if inverse (first dimensions)
							   0)
						 (if inverse
						     (first (dims array))
						     (if (< (first (dims array))
							    (first dimensions))
							 (first (dims array))
							 (first dimensions)))))
			 (if (and (not inverse)
				  (< (first (dims array))
				     (first dimensions)))
			     (list (make-array (list (- (first dimensions)
							(first (dims array))))
					       :initial-element fill-with))))))
      (aops:combine (apply #'aops:stack
			   (append (list 0 (aops:each (lambda (a)
							(multidim-slice a (rest dimensions)
									:inverse inverse
									:fill-with fill-with))
						      (subseq (aops:split array 1)
							      (if (and inverse (< 0 (first dimensions)))
								  (first dimensions)
								  0)
							      (if inverse
								  (if (> 0 (first dimensions))
								      (+ (first dimensions)
									 (first (dims array)))
								      (first (dims array)))
								  (if (< (first (dims array))
									 (first dimensions))
								      (first (dims array))
								      (first dimensions)))))))))))

(defun scan-back (function input &optional output)
  (if (not input)
      output (if (not output)
		 (scan-back function (cddr input)
			    (funcall function (second input)
				     (first input)))
		 (scan-back function (rest input)
			    (funcall function (first input)
				     output)))))

(defun make-back-scanner (function)
  "Build a function to scan across an array, modifying each value as determined by prior values."
  (lambda (sub-array)
    (let ((args (list (aref sub-array 0))))
      (loop for index from 1 to (1- (length sub-array))
	 do (setf args (cons (aref sub-array index)
			     args)
		  (aref sub-array index)
		  (scan-back function args)))
      sub-array)))

(defun apply-marginal (function array axis default-axis)
  "Apply a transformational function to an array. The function is applied row by row, with the option to pivot the array into a specific orientation for the application of the function."
  (let* ((new-array (copy-array array))
	 (a-rank (rank array))
	 (axis (if axis axis default-axis)))
    (if (> axis (1- a-rank))
	(error "Invalid axis.")
	(progn (if (not (= axis (1- a-rank)))
		   (setq new-array (aops:permute (rotate-left (- a-rank 1 axis)
							      (alexandria:iota a-rank))
						 new-array)))
	       (aops:margin (lambda (sub-array) (funcall function sub-array))
			    new-array (1- a-rank))
	       (if (not (= axis (1- a-rank)))
		   (aops:permute (rotate-right (- a-rank 1 axis)
					       (alexandria:iota a-rank))
				 new-array)
		   new-array)))))

(defun expand-array (degrees array axis default-axis &key (compress-mode nil))
  "Expand or replicate sections of an array as specified by an array of 'degrees.'"
  (let* ((new-array (copy-array array))
	 (a-rank (rank array))
	 (axis (if axis axis default-axis))
	 (singleton-array (loop for dim in (dims array) always (= 1 dim)))
	 (char-array? (or (eql 'character (element-type array))
			  (eql 'base-char (element-type array)))))
    (if (and singleton-array (< 1 a-rank))
    	(setq array (make-array (list 1)
				:element-type (element-type array)
				:displaced-to array)))
    (if (> axis (1- a-rank))
	(error "Invalid axis.")
	(progn (if (not (= axis (1- a-rank)))
		   (setq new-array (aops:permute (rotate-left (- a-rank 1 axis)
							      (alexandria:iota a-rank))
						 new-array)))
	       (let ((array-segments (aops:split new-array 1))
		     (segment-index 0))
		 (let* ((expanded (loop for degree in degrees
				     append (cond ((< 0 degree)
						   (loop for items from 1 to degree
						      collect (aref array-segments segment-index)))
						  ((and (= 0 degree)
							(not compress-mode))
						   (list (if (arrayp (aref array-segments 0))
							     (make-array (dims (aref array-segments 0))
									 :element-type (element-type array)
									 :initial-element (if char-array? #\  0))
							     (if char-array? #\  0))))
						  ((> 0 degree)
						   (loop for items from -1 downto degree
						      collect (if (arrayp (aref array-segments 0))
								  (make-array (dims (aref array-segments 0))
									      :element-type (element-type array)
									      :initial-element
									      (if char-array? #\  0))
								  (if char-array? #\  0)))))
				     do (if (and (not singleton-array)
						 (or compress-mode (< 0 degree)))
					    (incf segment-index 1))))
			(output (funcall (if (< 1 (rank array))
					     #'aops:combine (lambda (x) x))
					 ;; combine the resulting arrays if the original is multidimensional,
					 ;; otherwise just make a vector
					 (make-array (length expanded)
						     :element-type (element-type array)
						     :initial-contents expanded))))
		   (if (not (= axis (1- a-rank)))
		       (aops:permute (rotate-right (- a-rank 1 axis)
						   (alexandria:iota a-rank))
				     output)
		       output)))))))

(defun partitioned-enclose (positions array axis default-axis)
  "Enclose parts of an input array partitioned according to the 'positions' argument."
  (let* ((indices (loop for p from 0 to (1- (length positions))
		     when (not (= 0 (aref positions p)))
		     collect p))
	 (source-array (copy-array array))
	 (a-rank (rank array))
	 (axis (if axis axis default-axis)))
    (if (> axis (1- a-rank))
	(error "Invalid axis.")
	(let ((source-segments (aops:split (if (not (= axis (1- a-rank)))
					       (aops:permute (rotate-left (- a-rank 1 axis)
									  (alexandria:iota a-rank))
							     source-array)
					       source-array)
					   1))
	      (output-segments nil))
	  (loop for index from 0 to (1- (length source-segments))
	     when (or output-segments (find index indices))
	     do (setq output-segments (if (find index indices)
					  (cons (list (aref source-segments index))
						output-segments)
					  (cons (cons (aref source-segments index)
						      (first output-segments))
						(rest output-segments)))))
	  (apply #'vector (loop for seg in (reverse output-segments)
			     collect (let ((sub-matrix (aops:combine (apply #'vector (reverse seg)))))
				       (if (not (= axis (1- a-rank)))
					   (aops:permute (rotate-right (- a-rank 1 axis)
								       (alexandria:iota a-rank))
							 sub-matrix)
					   sub-matrix))))))))

(defun enlist (vector)
  "Create a vector containing all elements of the argument in ravel order, breaking down nested and multidimensional arrays."
  (if (arrayp vector)
      (setq vector (aops:flatten vector)))
  (if (and (vectorp vector)
	   (loop for element from 0 to (1- (length vector))
	      always (not (arrayp (aref vector element)))))
      vector
      (let ((current-segment nil)
	    (segments nil))
	(dotimes (index (length vector))
	  (let ((element (aref vector index)))
	    (if (arrayp element)
		(if (not (= 0 (array-total-size element)))
		    ;; skip empty vectors
		    (setq segments (cons (enlist element)
					 (if current-segment
					     (cons (make-array (list (length current-segment))
							       :initial-contents (reverse current-segment))
						   segments)
					     segments))
			  current-segment nil))
		(setq current-segment (cons element current-segment)))))
	(if current-segment (setq segments (cons (make-array (list (length current-segment))
							     :initial-contents (reverse current-segment))
						 segments)))
	(apply #'aops:stack (cons 0 (reverse segments))))))

(defun reshape-array-fitting (array adims)
  "Reshape an array into a given set of dimensions, truncating or repeating the elements in the array until the dimensions are satisfied if the new array's size is different from the old."
  (let* ((original-length (array-total-size array))
	 (total-length (apply #'* adims))
	 (displaced-array (make-array (list original-length)
				      :element-type (element-type array)
				      :displaced-to array)))
    (aops:reshape (make-array (list total-length)
			      :element-type (element-type array)
			      :initial-contents (loop for index from 0 to (1- total-length)
						   collect (aref displaced-array (mod index original-length))))
		  adims)))

(defun sprfact (n)
  "Recursive factorial-computing function. Based on P. Luschny's code."
  (let ((p 1) (r 1) (NN 1) (log2n (floor (log n 2)))
	(h 0) (shift 0) (high 1) (len 0))
    (labels ((prod (n)
	       (declare (fixnum n))
	       (let ((m (ash n -1)))
		 (cond ((= m 0) (incf NN 2))
		       ((= n 2) (* (incf NN 2)
				   (incf NN 2)))
		       (t (* (prod (- n m))
			     (prod m)))))))
      (loop while (/= h n) do
	   (incf shift h)
	   (setf h (ash n (- log2n)))
	   (decf log2n)
	   (setf len high)
	   (setf high (if (oddp h)
			  h (1- h)))
	   (setf len (ash (- high len) -1))
	   (cond ((> len 0)
		  (setf p (* p (prod len)))
		  (setf r (* r p)))))
      (ash r shift))))

(defun binomial (n k)
  "Find a binomial using the above sprfact function."
  (labels ((prod-enum (s e)
	     (do ((i s (1+ i)) (r 1 (* i r))) ((> i e) r)))
	   (sprfact (n) (prod-enum 1 n)))
    (/ (prod-enum (- (1+ n) k) n) (sprfact k))))

(defun array-inner-product (operand1 operand2 function1 function2)
  "Find the inner product of two arrays with two functions."
  (funcall (lambda (result)
	     ;; disclose the result if the right argument was a vector and there is
	     ;; a superfluous second dimension
	     (if (vectorp operand1)
		 (aref (aops:split result 1) 0)
		 (if (vectorp operand2)
		     (let ((nested-result (aops:split result 1)))
		       (make-array (list (length nested-result))
				   :initial-contents (loop for index from 0 to (1- (length nested-result))
							  collect (aref (aref nested-result index) 0))))
		     result)))
	   (aops:each (lambda (sub-vector)
			(if (vectorp sub-vector)
			    (reduce function2 sub-vector)
			    (funcall function2 sub-vector)))
		      (aops:outer function1
				  ;; enclose the argument if it is a vector
				  (if (vectorp operand1)
				      (vector operand1)
				      (aops:split (aops:permute (alexandria:iota (rank operand1))
								operand1)
						  1))
				  (if (vectorp operand2)
				      (vector operand2)
				      (aops:split (aops:permute (reverse (alexandria:iota (rank operand2)))
								operand2)
						  1))))))

(defun index-of (to-search set count-from)
  "Find occurrences of members of one set in an array and create a corresponding array with values equal to the indices of the found values in the search set, or one plus the maximum possible found item index if the item is not found in the search set."
  (if (not (vectorp set))
      (error "Rank error.")
      (let* ((to-find (remove-duplicates set :from-end t))
	     (maximum (+ count-from (length set)))
	     (results (make-array (dims to-search) :element-type 'number)))
	(dotimes (index (array-total-size results))
	  (let* ((search-index (row-major-aref to-search index))
		 (found (position search-index to-find)))
	    (setf (row-major-aref results index)
		  (if found (+ count-from found)
		      maximum))))
	results)))

(defun alpha-compare (atomic-vector compare-by)
  "Compare the contents of a vector according to their positions in an array, as when comparing an array of letters by their positions in the alphabet."
  (lambda (item1 item2)
    (flet ((assign-char-value (char)
	     (let ((vector-pos (position char atomic-vector)))
	       (if vector-pos vector-pos (length atomic-vector)))))
      (if (numberp item1)
	  (or (characterp item2)
	      (if (= item1 item2)
		  :equal (funcall compare-by item1 item2)))
	  (if (characterp item1)
	      (if (characterp item2)
		  (if (char= item1 item2)
		      :equal (funcall compare-by (assign-char-value item1)
				      (assign-char-value item2)))))))))
  
(defun vector-grade (compare-by vector1 vector2 &optional index)
  "Compare two vectors by the values of each element, giving priority to elements proportional to their position in the array, as when comparing words by the alphabetical order of the letters."
  (let ((index (if index index 0)))
    (cond ((>= index (length vector1))
	   (not (>= index (length vector2))))
	  ((>= index (length vector2)) nil)
	  (t (let ((compared (funcall compare-by (aref vector1 index)
				      (aref vector2 index))))
	       (if (eq :equal compared)
		   (vector-grade compare-by vector1 vector2 (1+ index))
		   compared))))))

(defun grade (array compare-by count-from)
  "Grade an array, using vector grading if 1-dimensional or decomposing the array into vectors and comparing those if multidimensional."
  (let* ((array (if (= 1 (rank array))
		    array (aops:split array 1)))
	 (vector (make-array (list (length array))))
	 (graded-array (make-array (list (length array))
				   :initial-contents (mapcar (lambda (item) (+ item count-from))
							     (alexandria:iota (length array))))))
    (loop for index from 0 to (1- (length vector))
       do (setf (aref vector index)
		(if (and (arrayp (aref array index))
			 (< 1 (rank (aref array index))))
		    (grade (aref array index)
			   compare-by count-from)
		    (aref array index))))
    (stable-sort graded-array (lambda (1st 2nd)
				(let ((val1 (aref vector (- 1st count-from)))
				      (val2 (aref vector (- 2nd count-from))))
				  (cond ((not (arrayp val1))
					 (if (arrayp val2)
					     (funcall compare-by val1 (aref val2 0))
					     (let ((output (funcall compare-by val1 val2)))
					       (and output (not (eq :equal output))))))
					((not (arrayp val2))
					 (funcall compare-by (aref val1 0)
						  val2))
					(t (vector-grade compare-by val1 val2))))))
    graded-array))

(defun array-grade (compare-by array)
  "Grade an array."
  (aops:each (lambda (item)
	       (let ((coords nil))
		 (run-dim compare-by (lambda (found indices)
				       (if (char= found item)
					   (setq coords indices))))
		 (make-array (list (length coords))
			     :initial-contents (reverse coords))))
	     array))

(defun find-array (array target)
  "Find instances of an array within a larger array."
  (let ((target-head (row-major-aref target 0))
	(target-dims (append (if (< (rank target)
				    (rank array))
				 (loop for index from 0 to (1- (- (rank array)
								  (rank target)))
				    collect 1))
			     (dims target)))
	(output (make-array (dims array) :initial-element 0))
	(match-coords nil)
	(confirmed-matches nil))
    (run-dim array (lambda (element coords)
		     (if (equal element target-head)
			 (setq match-coords (cons coords match-coords)))))
    (loop for match in match-coords
       do (let ((target-index 0)
		(target-matched t)
		(target-displaced (make-array (list (array-total-size target))
					      :displaced-to target)))
	    (run-dim array (lambda (element coords)
			     (declare (ignore coords))
			     (if (and (< target-index (length target-displaced))
				      (not (equal element (aref target-displaced target-index))))
				 (setq target-matched nil))
			     (incf target-index 1))
		     :start-at match :limit target-dims)
	    ;; check the target index in case the elements in the searched array ran out
	    (if (and target-matched (= target-index (length target-displaced)))
		(setq confirmed-matches (cons match confirmed-matches)))))
    (loop for match in confirmed-matches
       do (setf (apply #'aref (cons output match))
		1))
    output))

(defun run-dim (array function &key (dimensions nil) (indices nil) (start-at nil) (limit nil) (elision nil))
  "Iterate across a range of elements in an array, with an optional starting point, limits and elision."
  (let ((dimensions (if dimensions dimensions (dims array))))
    (flet ((for-element (elix &optional source-index)
	     (if source-index (setq elix source-index))
	     (if (< (length indices)
		    (1- (length dimensions)))
		 (run-dim array function :indices (append indices (list elix)) :elision elision
			  :dimensions dimensions :start-at start-at :limit limit)
		 (funcall function (apply #'aref (cons array (append indices (list elix))))
			  (append indices (list elix))))))
      (let ((elided (nth (length indices) elision))
	    (this-start (nth (length indices) start-at)))
	(if (and elision elided)
	    (if (listp elided)
		(loop for elix from 0 to (1- (length elided))
		   do (for-element elix (nth elix elided)))
		(for-element elided))
	    (loop for elix from (if this-start this-start 0)
	       to (min (if limit
			   (+ (if this-start this-start 0)
			      -1 (nth (length indices) limit))
			   (1- (nth (length indices) dimensions)))
		       (1- (nth (length indices) dimensions)))
	       do (for-element elix)))))))

(defun aref-eliding (array indices &key (set nil))
  "Find an element in an array with aref or a sub-array of elements which may be elided or located along multiple elements of given axes in an array."
  (if (and (not set)
	   (= (length indices)
	      (rank array))
	   (loop for index in indices always (numberp index)))
      ;; wrap discrete elements in vectors in keeping with APL's data model
      (vector (apply #'aref (cons array indices)))
      (let* ((adims (dims array))
	     (el-indices nil)
	     (indices (if (= (length indices)
			     (rank array))
			  indices (loop for index from 0 to (1- (rank array))
				     collect (if (nth index indices)
						 (nth index indices)
						 nil))))
	     (sub-dims (loop for index from 0 to (1- (length indices))
			  when (listp (nth index indices))
			  do (setq el-indices (cons index el-indices))
			  when (listp (nth index indices))
			  collect (if (nth index indices)
				      (length (nth index indices))
				      (nth index adims))))
	     (sub-array (make-array sub-dims :element-type (element-type array))))
	(setq el-indices (reverse el-indices))
	(run-dim array (lambda (value coords)
			 (if set (if (functionp set)
				     (setf (apply #'aref array coords)
					   (let ((out-val (funcall set value)))
					     (if (is-singleton out-val)
						 (aref out-val 0)
						 out-val)))
				     (setf (apply #'aref array coords)
					   (if (is-singleton set)
					       (aref set 0)
					       set)))
			     (setf (apply #'aref (cons sub-array (loop for index in el-indices
								    collect (if (nth index indices)
										(position (nth index coords)
											  (nth index indices))
										(nth index coords)))))
				   value)))
		 :elision indices)
	sub-array)))

(defun mix-arrays (axis arrays &optional max-dims)
  "Combine multiple arrays into a single array one rank higher. Vectors may be stacked to form a 2D array, 2D arrays may be stacked to form a 3D array, etc. Arrays with smaller dimensions than the largest array in the stack have missing elements replaced with 0s for numeric arrays or blanks for character arrays."
  (let ((permute-dims (if (vectorp arrays)
			  (alexandria:iota (1+ (rank (aref arrays 0))))))
	(max-dims (if max-dims max-dims
		      (let ((mdims (make-array (list (array-total-size arrays))
					       :displaced-to (aops:each #'dims arrays))))
			(loop for dx from 0 to (1- (length (aref mdims 0)))
			   collect (apply #'max (array-to-list (aops:each (lambda (n) (nth dx n))
									  mdims))))))))
    ;;(print (list ))
    (if (vectorp arrays)
	(apply #'aops:stack
	       (cons axis (loop for index from 0 to (1- (length arrays))
			     collect (aops:permute (rotate-right axis permute-dims)
						   (array-promote
						    (if (not (equalp max-dims (dims (aref arrays index))))
							(let* ((this-eltype (element-type (aref arrays index)))
							       (out-array (make-array max-dims
										      :element-type this-eltype
										      :initial-element
										      (cond ((eql 'character
												  this-eltype)
											     #\ )
											    (t 0)))))
							  (run-dim (aref arrays index)
								   (lambda (item coords)
								     (setf (apply #'aref (cons out-array coords))
									   item)))
							  out-array)
							(aref arrays index)))))))
	(aops:combine (aops:each (lambda (sub-arrays)
				   (mix-arrays axis sub-arrays max-dims))
				 (aops:split arrays 1))))))

(defun ravel (count-from array &optional axes)
  "Produce a vector from the elements of a multidimensional array."
  (flet ((linsert (newelt lst index)
	   (if (= 0 index)
	       (setq lst (cons newelt lst))
	       (push newelt (cdr (nthcdr (1- index) lst))))
	   lst))
    (if (and (not axes)
	     (vectorp array))
	array (if axes
		  (cond ((and (= 1 (length (first axes)))
			      (not (integerp (aref (first axes) 0))))
			 (make-array (if (and (vectorp (aref (first axes) 0))
					      (= 0 (length (aref (first axes) 0))))
					 (append (dims array)
						 (list 1))
					 (linsert 1 (dims array)
						  (- (ceiling (aref (first axes) 0))
						     count-from)))
				     :displaced-to (copy-array array)))
			((and (< 1 (length (first axes)))
			      (or (< (aref (first axes) 0)
				     0)
				  (> (aref (first axes)
					   (1- (length (first axes))))
				     (rank array))
				  (not (loop for index from 1 to (1- (length (first axes)))
					  always (= (aref (first axes) index)
						    (1+ (aref (first axes)
							      (1- index))))))))
			 (error
			  "Dimension indices must be consecutive and within the array's number of dimensions."))
			((< 1 (length (first axes)))
			 (let* ((axl (mapcar (lambda (item) (- item count-from))
					     (array-to-list (first axes))))
				(collapsed (apply #'* (mapcar (lambda (index) (nth index (dims array)))
							      axl))))
			   (labels ((dproc (dms &optional index output)
				      (let ((index (if index index 0)))
					(if (not dms)
					    (reverse output)
					    (dproc (if (= index (first axl))
						       (nthcdr (length axl) dms)
						       (rest dms))
						   (1+ index)
						   (cons (if (= index (first axl))
							     collapsed (first dms))
							 output))))))
			     (make-array (dproc (dims array))
					 :displaced-to (copy-array array))))))
		  (make-array (list (array-total-size array))
			      :element-type (element-type array)
			      :displaced-to (copy-array array))))))

(defun re-enclose (matrix axes)
  "Convert an array into a set of sub-arrays listed within a larger array. The dimensions of the containing array and the sub-arrays will be some combination of the dimensions of the original array. For example, a 2 x 3 x 4 array be be composed into a 3-element vector containing 2 x 4 dimensional arrays."
  (labels ((make-enclosure (inner-dims type dimensions)
	     (loop for d from 0 to (1- (first dimensions))
		collect (if (= 1 (length dimensions))
			    (make-array inner-dims :element-type type)
			    (make-enclosure inner-dims type (rest dimensions))))))
    (cond ((= 1 (length axes))
	   ;; if there is only one axis just split the array, with permutation first if not splitting
	   ;; along the last axis
	   (if (= (1- (rank matrix))
		  (aref axes 0))
	       (aops:split matrix (1- (rank matrix)))
	       (aops:split (aops:permute (sort (alexandria:iota (rank matrix))
					       (lambda (a b)
						 (declare (ignore a))
						 (= b (aref axes 0))))
					 matrix)
			   (1- (rank matrix)))))
	  ((not (apply #'< (array-to-list axes)))
	   (error "Elements in an axis argument to the enclose function must be in ascending order."))
	  ((let ((indices (mapcar (lambda (item) (+ item (aref axes 0)))
				  (alexandria:iota (- (rank matrix)
						      (- (rank matrix)
							 (length axes)))))))
	     (and (= (first (last indices))
		     (1- (rank matrix)))
		  (loop for index from 0 to (1- (length indices))
		     always (= (nth index indices)
			       (aref axes index)))))
	   ;; if there are multiple indices in the axis argument leading up to the last axis,
	   ;; all that's needed is to split the array along the first of the indices
	   (if (> (rank matrix)
		  (length axes))
	       (aops:split matrix (aref axes 0))
	       (make-array (list 1) :initial-element matrix)))
	  (t (let* ((matrix-dims (dims matrix))
		    (axis-list (array-to-list axes))
		    (outer-dims nil)
		    (inner-dims nil))
	       ;; otherwise, start by separating the dimensions of the original array into sets of dimensions
	       ;; for the output array and each of its enclosed arrays
	       (loop for axis from 0 to (1- (rank matrix))
		  do (if (find axis axis-list)
			 (setq inner-dims (cons axis inner-dims))
			 (setq outer-dims (cons axis outer-dims))))
	       (setq inner-dims (reverse inner-dims)
		     outer-dims (reverse outer-dims))
	       ;; create a new blank array of the outer dimensions containing blank arrays of the inner dimensions
	       (let ((new-matrix (make-array (loop for dm in outer-dims
						collect (nth dm matrix-dims))
					     :initial-contents
					     (make-enclosure (loop for dm in inner-dims
								collect (nth dm matrix-dims))
							     (element-type matrix)
							     (loop for dm in outer-dims
								collect (nth dm matrix-dims))))))
		 ;; iterate through the original array and for each element, apply the same separation
		 ;; to their coordinates that was done to the original array's dimensions and apply the two sets
		 ;; of coordinates to set each value in the nested output arrays to the corresponding values in
		 ;; the original array
		 (run-dim matrix (lambda (item coords)
				   (setf (apply #'aref (cons (apply #'aref (cons new-matrix
										 (loop for d in outer-dims
										    collect (nth d coords))))
							     (loop for d in inner-dims collect (nth d coords))))
					 item)))
		 new-matrix))))))

(defun invert-matrix (in-matrix)
  "Find the inverse of a square matrix."
  (let ((dim (array-dimension in-matrix 0))   ;; dimension of matrix
	(det 1)                               ;; determinant of matrix
	(l nil)                               ;; permutation vector
	(m nil)                               ;; permutation vector
	(temp 0)
	(out-matrix (make-array (dims in-matrix))))

    (if (not (equal dim (array-dimension in-matrix 1)))
	(error "invert-matrix () - matrix not square"))

    ;; (if (not (equal (array-dimensions in-matrix)
    ;;                 (array-dimensions out-matrix)))
    ;;     (error "invert-matrix () - matrices not of the same size"))

    ;; copy in-matrix to out-matrix if they are not the same
    (when (not (equal in-matrix out-matrix))
      (do ((i 0 (1+ i)))
	  ((>= i dim))    
	(do ((j 0 (1+ j)))
	    ((>= j dim)) 
	  (setf (aref out-matrix i j) (aref in-matrix i j)))))

    ;; allocate permutation vectors for l and m, with the 
    ;; same origin as the matrix
    (setf l (make-array `(,dim)))
    (setf m (make-array `(,dim)))

    (do ((k 0 (1+ k))
	 (biga 0)
	 (recip-biga 0))
	((>= k dim))

      (setf (aref l k) k)
      (setf (aref m k) k)
      (setf biga (aref out-matrix k k))

      ;; find the biggest element in the submatrix
      (do ((i k (1+ i)))
	  ((>= i dim))    
	(do ((j k (1+ j)))
	    ((>= j dim)) 
	  (when (> (abs (aref out-matrix i j)) (abs biga))
	    (setf biga (aref out-matrix i j))
	    (setf (aref l k) i)
	    (setf (aref m k) j))))

      ;; interchange rows
      (if (> (aref l k) k)
	  (do ((j 0 (1+ j))
	       (i (aref l k)))
	      ((>= j dim)) 
	    (setf temp (- (aref out-matrix k j)))
	    (setf (aref out-matrix k j) (aref out-matrix i j))
	    (setf (aref out-matrix i j) temp)))

      ;; interchange columns 
      (if (> (aref m k) k)
	  (do ((i 0 (1+ i))
	       (j (aref m k)))
	      ((>= i dim)) 
	    (setf temp (- (aref out-matrix i k)))
	    (setf (aref out-matrix i k) (aref out-matrix i j))
	    (setf (aref out-matrix i j) temp)))

      ;; divide column by minus pivot (value of pivot 
      ;; element is in biga)
      (if (equalp biga 0) 
	  (return-from invert-matrix 0))
      (setf recip-biga (/ 1 biga))
      (do ((i 0 (1+ i)))
	  ((>= i dim)) 
	(if (not (equal i k))
	    (setf (aref out-matrix i k) 
		  (* (aref out-matrix i k) (- recip-biga)))))

      ;; reduce matrix
      (do ((i 0 (1+ i)))
	  ((>= i dim)) 
	(when (not (equal i k))
	  (setf temp (aref out-matrix i k))
	  (do ((j 0 (1+ j)))
	      ((>= j dim)) 
	    (if (not (equal j k))
		(incf (aref out-matrix i j) 
		      (* temp (aref out-matrix k j)))))))

      ;; divide row by pivot
      (do ((j 0 (1+ j)))
	  ((>= j dim)) 
	(if (not (equal j k))
	    (setf (aref out-matrix k j)
		  (* (aref out-matrix k j) recip-biga))))

      (setf det (* det biga)) ;; product of pivots
      (setf (aref out-matrix k k) recip-biga)) ;; k loop

    ;; final row & column interchanges
    (do ((k (1- dim) (1- k)))
	((< k 0))
      (if (> (aref l k) k)
	  (do ((j 0 (1+ j))
	       (i (aref l k)))
	      ((>= j dim))
	    (setf temp (aref out-matrix j k))
	    (setf (aref out-matrix j k) 
		  (- (aref out-matrix j i)))
	    (setf (aref out-matrix j i) temp)))
      (if (> (aref m k) k)
	  (do ((i 0 (1+ i))
	       (j (aref m k)))
	      ((>= i dim))
	    (setf temp (aref out-matrix k i))
	    (setf (aref out-matrix k i) 
		  (- (aref out-matrix j i)))
	    (setf (aref out-matrix j i) temp))))
    det ;; return determinant
    out-matrix))
