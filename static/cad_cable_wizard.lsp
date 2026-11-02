;;; 多氟多电缆长度自动统计 - CAD 分步引导向导（自包含，含导出命令）
;;; 只需 APPLOAD 本文件，然后输入 DCW（或 DDFD_CABLE_WIZARD），按菜单一步步做即可。支持中望 CAD 2026 和 AutoCAD 2018。
;;;
;;; 六个步骤（菜单和分步命令一一对应，可以随时跳到任意一步，想做哪层做哪层）:
;;;   1 建楼层     DDFD_CABLE_LAYERS      写出楼层（可含 B1F），自动创建 CABLE_* 图层
;;;   2 定义房间   DDFD_CABLE_ROOMS       给闭合多段线写房间名称（放到 CABLE_ROOM_nF）
;;;   3 标柜子     DDFD_CABLE_CABINETS    点柜子出线点并写柜名文字（柜名已标过会提醒）
;;;   4 画通道     DDFD_CABLE_ROUTES      沿电缆沟/桥架画走线通道（自动开端点捕捉）
;;;   5 标竖井     DDFD_CABLE_SHAFTS      标跨楼层竖井（自动写 ZJn_楼层 配对文字）
;;;   6 检查导出   DDFD_CABLE_EXPORT_RUN  体检后自动导出4个CSV到桌面，回网页上传计算
;;;
;;; 其他命令:
;;;   DCW                      打开向导菜单（DDFD_CABLE_WIZARD 的短命令）
;;;   DCV                      定义总览：每层的房间、房间里的柜子、通道、竖井配对和问题清单（DDFD_CABLE_LIST 同）
;;;   DDFD_EXPORT_CABLE_ROUTE  仅导出4个CSV（与 cad_export_cable_route.lsp 相同，可手动选目录）
;;;   DDFD_ROOM_CHECK          检查房间：列出将导出的房间，定位房间图层上未命名/无效的多段线
;;;   DDFD_CLEAN_ROOM_LAYERS   把房间图层上未命名的多段线移到 0 层（先确认，可 U 撤销）
;;;
;;; 面板调用的函数在文件末尾（ddfd:floors、ddfd:cabinets 等），总览文件格式见“定义总览”一节。
;;;
;;; 图层约定（n 为楼层号 1~99，地下室写 B1F、B2F）：
;;;   CABLE_CABINET_nF  柜子出线点文字     CABLE_ROUTE_nF  电缆沟/桥架中心线
;;;   CABLE_SHAFT_nF    竖井文字（同一竖井各层命名 ZJ1_1F / ZJ1_2F 配对）
;;;   CABLE_ROOM_nF     房间边界（只有“定义房间”写过名称的多段线才算房间）
;;;
;;; 导出规则：只导出模型空间（布局里的不算），全部读 DXF 数据，不依赖 COM。
;;;   柜子/竖井：TEXT、MTEXT（自动去格式）、块（取第一个非空属性值，没有属性就用块名）；
;;;   路径：LINE、LWPOLYLINE、POLYLINE（含圆弧段，长度按弧长）、ARC；SPLINE、椭圆等不导出，导出后会列出句柄。

(vl-load-com)

;; 改动本文件时同步更新版本号，加载时会打印，便于确认 CAD 里用的是哪一版
(setq *ddfd-cable-version* "2026-11-02-live")
;; 网页版工作台地址，第6步导出后可直接打开
(setq *ddfd-web-url* "https://2ci.sen666.cn/")

;;; ================= 通用与导出部分 =================
;; 本段原样复制到 cad_export_cable_route.lsp（python tools\lisp_test\sync_export_lsp.py），两份必须逐字一致。
;; 导出只读 DXF 数据、不调用 COM（accoreconsole 和部分 ZWCAD 没有 COM）；只有动态块取原块名时试一次 COM，出错不影响导出。

;; —— 字符串工具 ——

;; 把 str 里的 old 全部换成 new（vl-string-subst 只换第一处）；从替换后的位置接着找，new 里含 old 也不会死循环
(defun ddfd-string-replace-all (new old str / pos)
  (setq str (if str (vl-princ-to-string str) "") pos 0)
  (if (/= old "")
    (while (setq pos (vl-string-search old str pos))
      (setq str (strcat (substr str 1 pos) new (substr str (+ pos (strlen old) 1)))
            pos (+ pos (strlen new)))))
  str)

;; CSV 单元格：整格加双引号，内容里的每个双引号都写成两个
(defun ddfd-csv-escape (s)
  (strcat "\"" (ddfd-string-replace-all "\"\"" "\"" s) "\""))

;; 去掉首尾的 ASCII 空白
(defun ddfd-string-trim (s)
  (vl-string-trim " \t\r\n" (if s (vl-princ-to-string s) "")))

;; 手输/粘贴的文件夹路径：去掉首尾空白和双引号（资源管理器“复制文件地址”会带引号）
(defun ddfd-clean-path (s)
  (vl-string-trim " \t\r\n\"" (if s s "")))

;; MBCS 版 AutoLISP（AutoCAD 2020 及更早、LISPSYS=0、部分 ZWCAD）的字符串是 GBK 字节：一个汉字两个字节，
;; 尾字节可能落在 ASCII 范围（\ { } 和字母都有可能）；Unicode 版一个汉字就是一个字符。用 "中" 的长度区分两者
(defun ddfd-mbcs-p () (/= (strlen "中") 1))

;; 把字符串拆成单个字符的表；MBCS 下 GBK 双字节字符整体算一个，逐字处理时不会把汉字尾字节当成 ASCII
(defun ddfd-string-chars (s / codes mbcs c res)
  (setq codes (vl-string->list (if s (vl-princ-to-string s) "")) mbcs (ddfd-mbcs-p))
  (while codes
    (setq c (car codes) codes (cdr codes))
    (if (and mbcs (<= 129 c 254) codes)
      (setq res (cons (vl-list->string (list c (car codes))) res) codes (cdr codes))
      (setq res (cons (vl-list->string (list c)) res))))
  (reverse res))

;; 单个字符的 ASCII 码；汉字等非 ASCII 字符返回 0
(defun ddfd-ascii-code (ch / c)
  (if (and ch (= (strlen ch) 1) (< (setq c (ascii ch)) 128)) c 0))

(defun ddfd-digit-p (ch) (<= 48 (ddfd-ascii-code ch) 57))

(defun ddfd-alnum-p (ch / c)
  (setq c (ddfd-ascii-code ch))
  (or (<= 48 c 57) (<= 65 c 90) (<= 97 c 122)))

;; 单行文字（TEXT、属性）的 %% 控制码：%%u %%o %%k（下划线/上划线/删除线开关）去掉，%%% 为 %，%%nnn 为对应 ASCII 字符；
;; %%c %%d %%p 换成图上显示的 Φ ° ±：清册里直径一般写 Φ（CAD 显示的直径符号不在 GBK 里，而 CSV 按 GBK 写出），
;; 这样 CSV 和柜子清单里看到的就是图上的字，清册照着写就能对上
(defun ddfd-text-plain (s / chars out c n d2 d3 code)
  (setq chars (ddfd-string-chars s))
  (while chars
    (setq c (car chars))
    (if (and (= c "%") (= (cadr chars) "%") (setq n (caddr chars)))
      (progn
        (setq d2 (cadddr chars) d3 (car (cddddr chars)))
        (cond
          ((member n '("c" "C")) (setq out (cons "Φ" out) chars (cdddr chars)))
          ((member n '("d" "D")) (setq out (cons "°" out) chars (cdddr chars)))
          ((member n '("p" "P")) (setq out (cons "±" out) chars (cdddr chars)))
          ((member n '("u" "U" "o" "O" "k" "K")) (setq chars (cdddr chars)))
          ((= n "%") (setq out (cons "%" out) chars (cdddr chars)))
          ((and (ddfd-digit-p n) (ddfd-digit-p d2) (ddfd-digit-p d3)
                (<= 32 (setq code (atoi (strcat n d2 d3))) 126))
           (setq out (cons (chr code) out) chars (cdr (cddddr chars))))
          (T (setq out (cons c out) chars (cdr chars)))))
      (setq out (cons c out) chars (cdr chars))))
  (apply 'strcat (reverse out)))

;; 多行文字去格式：\P \N \~ 换成空格；去掉编组花括号；\f \F \H \W \Q \T \A \C \c \p 连同参数（到分号为止）去掉；
;; \L \l \O \o \K \k 开关去掉；堆叠 \Sa^b; \Sa/b; \Sa#b; 写成 a/b；\\ \{ \} 还原成字符；认不出的 \x 原样保留
;; （\U+XXXX：Unicode 版 AutoLISP 的 vl-string->list 会直接换成对应字符；MBCS 版里只有 GBK 以外的字才这样写，保留原样）。
;; 最后按单行文字处理 %% 控制码
(defun ddfd-mtext-plain (s / chars out c n)
  (setq chars (ddfd-string-chars s))
  (while chars
    (setq c (car chars) chars (cdr chars))
    (cond
      ((member c '("{" "}")))
      ((and (= c "\\") chars)
       (setq n (car chars))
       (cond
         ((member n '("P" "N" "~")) (setq out (cons " " out) chars (cdr chars)))
         ((member n '("\\" "{" "}")) (setq out (cons n out) chars (cdr chars)))
         ((member n '("L" "l" "O" "o" "K" "k")) (setq chars (cdr chars)))
         ((member n '("f" "F" "H" "W" "Q" "T" "A" "C" "c" "p"))
          (while (and chars (/= (car chars) ";")) (setq chars (cdr chars)))
          (setq chars (cdr chars)))
         ((= n "S")
          (setq chars (cdr chars))
          (while (and chars (/= (car chars) ";"))
            (setq out (cons (if (member (car chars) '("^" "#")) "/" (car chars)) out)
                  chars (cdr chars)))
          (setq chars (cdr chars)))
         (T (setq out (cons c out)))))
      (T (setq out (cons c out)))))
  (ddfd-text-plain (apply 'strcat (reverse out))))

;; MTEXT 内容超过 250 字时，前面的部分分段放在 3 组码里，按顺序拼上最后的 1 组码
(defun ddfd-mtext-raw (ent / s item)
  (setq s "")
  (foreach item ent (if (= (car item) 3) (setq s (strcat s (cdr item)))))
  (strcat s (cond ((cdr (assoc 1 ent))) (T ""))))

;; 柜名去掉 ASCII 空白（空格、制表、回车换行）。全角空格、不间断空格交给 Python（它会去掉全部 Unicode 空白）：
;; MBCS 版 AutoLISP 里字符串是 GBK 字节，按 160/12288 去字节会把生僻字的尾字节删坏
(defun ddfd-remove-spaces (s)
  (vl-list->string
    (vl-remove-if '(lambda (c) (member c '(9 10 13 32)))
                  (vl-string->list (if s (vl-princ-to-string s) "")))))

(defun ddfd-write-csv-row (fh cells / first)
  (setq first T)
  (foreach c cells
    (if first
      (setq first nil)
      (princ "," fh)
    )
    (princ (ddfd-csv-escape c) fh)
  )
  (write-line "" fh)
)

;; —— 楼层 ——

;; 从图层名解析楼层（不分大小写），规则与 Python 的 infer_floor_from_layer 相同，按顺序：
;;   1. B<n>F 且 B 前面不是字母或数字：地下室，CABLE_ROUTE_B1F -> B1F；
;;   2. 中文 一~九十九 加 层/楼，前面带“地下”或“负”算地下室：电缆沟二层 -> 2F，地下一层 -> B1F；
;;   3. <n>F（取完整的一串数字）：CABLE_ROUTE_12F -> 12F，CABLE_ROUTE_01F -> 1F。
;; 楼层号只认 1~99，都认不出返回 ""
(defun ddfd-layer-floor (layer / chars len i j n res)
  (setq chars (ddfd-string-chars layer) len (length chars) res "" i 0)
  (while (and (= res "") (< i len))
    (if (and (member (nth i chars) '("B" "b"))
             (or (= i 0) (not (ddfd-alnum-p (nth (1- i) chars)))))
      (progn
        (setq j (1+ i))
        (while (ddfd-digit-p (nth j chars)) (setq j (1+ j)))
        (if (and (> j (1+ i)) (member (nth j chars) '("F" "f"))
                 (<= 1 (setq n (ddfd-chars-number chars (1+ i) j)) 99))
          (setq res (strcat "B" (itoa n) "F")))))
    (setq i (1+ i)))
  (if (= res "") (setq res (ddfd-layer-floor-cn chars)))
  (setq i 0)
  (while (and (= res "") (< i len))
    (if (and (ddfd-digit-p (nth i chars))
             (or (= i 0) (not (ddfd-digit-p (nth (1- i) chars)))))
      (progn
        (setq j i)
        (while (ddfd-digit-p (nth j chars)) (setq j (1+ j)))
        (if (and (member (nth j chars) '("F" "f"))
                 (<= 1 (setq n (ddfd-chars-number chars i j)) 99))
          (setq res (strcat (itoa n) "F")))))
    (setq i (1+ i)))
  res)

;; 数字字符 chars[from..to) 的值；超过 99 就不再往下算（只需判断是否在 1~99 内）
(defun ddfd-chars-number (chars from to / n)
  (setq n 0)
  (while (and (< from to) (<= n 99))
    (setq n (+ (* n 10) (- (ascii (nth from chars)) 48)) from (1+ from)))
  n)

;; 中文数字 零~九、两、十 的值，其他字符返回 nil
(defun ddfd-cn-digit (ch)
  (cdr (assoc ch '(("零" . 0) ("〇" . 0) ("一" . 1) ("二" . 2) ("两" . 2) ("三" . 3) ("四" . 4)
                   ("五" . 5) ("六" . 6) ("七" . 7) ("八" . 8) ("九" . 9) ("十" . 10)))))

;; 中文数字串（单字表）的值：一~九、十、十二、二十、二十三 这类写法，其他返回 nil（同 Python 的 chinese_number）
(defun ddfd-cn-number (run / ones)
  (cond
    ((not (member "十" run)) (if (null (cdr run)) (ddfd-cn-digit (car run))))
    ((= (car run) "十")
     (setq ones (cdr run))
     (cond ((null ones) 10)
           ((and (null (cdr ones)) (/= (car ones) "十")) (+ 10 (ddfd-cn-digit (car ones))))))
    ((= (cadr run) "十")
     (setq ones (cddr run))
     (cond ((null ones) (* 10 (ddfd-cn-digit (car run))))
           ((and (null (cdr ones)) (/= (car ones) "十"))
            (+ (* 10 (ddfd-cn-digit (car run))) (ddfd-cn-digit (car ones))))))))

;; 中文楼层：只看第一段紧挨着 层/楼 的中文数字（Python 也只取第一处），前面是“地下”或“负”就是地下室
(defun ddfd-layer-floor-cn (chars / len i j k n run res)
  (setq len (length chars) i 0 res "")
  (while (< i len)
    (if (and (ddfd-cn-digit (nth i chars))
             (or (= i 0) (not (ddfd-cn-digit (nth (1- i) chars)))))
      (progn
        (setq j i)
        (while (and (< j len) (ddfd-cn-digit (nth j chars))) (setq j (1+ j)))
        (if (member (nth j chars) '("层" "楼"))
          (progn
            (setq run nil k (1- j))
            (while (>= k i) (setq run (cons (nth k chars) run) k (1- k)))
            (if (and (setq n (ddfd-cn-number run)) (<= 1 n 99))
              (setq res (strcat (if (and (> i 0)
                                         (or (= (nth (1- i) chars) "负")
                                             (and (> i 1) (= (nth (1- i) chars) "下") (= (nth (- i 2) chars) "地"))))
                                  "B" "")
                                (itoa n) "F")))
            (setq i len)))))
    (setq i (1+ i)))
  res)

;; —— 柜子/竖井的位置和名称 ——

;; 定位点：TEXT/INSERT 的 10 组码是 OCS 坐标，要转到 WCS；MTEXT、POINT 的 10 组码本身就是 WCS。
;; 与旧版 COM 的 InsertionPoint 一致，TEXT 取 10 组码（文字基点），不取 11 组码（对齐点）
(defun ddfd-entity-point (ename / ent pt)
  (setq ent (entget ename) pt (cdr (assoc 10 ent)))
  (if (and pt (member (cdr (assoc 0 ent)) '("TEXT" "INSERT")))
    (trans pt ename 0)
    pt))

;; 块参照的第一个非空属性值：66 组码为 1 时，块参照后面紧跟着 ATTRIB 图元直到 SEQEND；多行属性按多行文字去格式
(defun ddfd-block-first-attr (ename / cur ed res)
  (setq res "")
  (if (= 1 (cdr (assoc 66 (entget ename))))
    (progn
      (setq cur (entnext ename))
      (while (and cur (= res "") (= "ATTRIB" (cdr (assoc 0 (setq ed (entget cur))))))
        (setq res (ddfd-string-trim
                    (if (assoc 101 ed)
                      (ddfd-mtext-plain (cdr (assoc 1 ed)))
                      (ddfd-text-plain (cdr (assoc 1 ed)))))
              cur (entnext cur)))))
  res)

;; 动态块参照的块名是匿名的 *U…：先按 DXF 找原块名（匿名块记录的 AcDbBlockRepBTag 扩展数据指向原块记录），
;; 找不到再试 COM 的 EffectiveName（放在 vl-catch-all-apply 里，控制台等没有 COM 的环境出错就用 *U… 原名）
(defun ddfd-block-effective-name (ename name / rec rep res)
  (if (wcmatch name "`**")
    (progn
      (if (and (setq rec (tblobjname "BLOCK" name))
               (setq rec (cdr (assoc 330 (entget rec))))
               (setq rep (cdadr (assoc -3 (entget rec '("AcDbBlockRepBTag")))))
               (setq rep (cdr (assoc 1005 rep)))
               (setq rep (handent rep)))
        (setq res (cdr (assoc 2 (entget rep)))))
      (if (not res)
        (progn
          (setq rep (vl-catch-all-apply
                      '(lambda () (vla-get-EffectiveName (vlax-ename->vla-object ename)))
                      nil))
          (if (and (= (type rep) 'STR) (/= rep "")) (setq res rep))))
      (if res res name))
    name))

(defun ddfd-insert-name (ename / nm)
  (setq nm (ddfd-block-first-attr ename))
  (if (= nm "")
    (ddfd-block-effective-name ename (cdr (assoc 2 (entget ename))))
    nm))

;; 柜名/竖井编号：TEXT 取 1 组码，MTEXT 取 3 组码各段加 1 组码并去格式，块参照取第一个非空属性值、没有就用块名；
;; 其他图元（点、线等）没有名称，返回 ""
(defun ddfd-entity-name (ename / ent typ)
  (setq ent (entget ename) typ (cdr (assoc 0 ent)))
  (cond
    ((= typ "TEXT") (ddfd-text-plain (cdr (assoc 1 ent))))
    ((= typ "MTEXT") (ddfd-mtext-plain (ddfd-mtext-raw ent)))
    ((= typ "INSERT") (ddfd-insert-name ename))
    (T "")))

(defun ddfd-ensure-folder (dir)
  (if (not (vl-file-directory-p dir))
    (vl-mkdir dir)
  )
)


(defun ddfd-room-name (ename / xd item value)
  (setq value "")
  (setq xd (assoc -3 (entget ename (list "DDFD_CABLE_ROOM"))))
  (if xd
    (progn
      (setq item (cadr xd))
      (if item (setq value (cdr (assoc 1000 (cdr item)))))
    )
  )
  (if value value "")
)

(defun ddfd-room-set-name (ename name / data)
  (regapp "DDFD_CABLE_ROOM")
  (setq data (entget ename))
  (entmod (append data (list (list -3 (list "DDFD_CABLE_ROOM" (cons 1000 name))))))
  (entupd ename)
)

(defun ddfd-room-has-arc (ename / ent typ cur vd item found)
  (setq ent (entget ename))
  (setq typ (cdr (assoc 0 ent)))
  (setq found nil)
  (if (= typ "LWPOLYLINE")
    (foreach item ent
      (if (and (= (car item) 42) (> (abs (cdr item)) 1e-9)) (setq found T))
    )
    (if (= typ "POLYLINE")
      (progn
        (setq cur (entnext ename))
        (while (and (not found) cur (= (cdr (assoc 0 (setq vd (entget cur)))) "VERTEX"))
          (if (and (assoc 42 vd) (> (abs (cdr (assoc 42 vd))) 1e-9)) (setq found T))
          (setq cur (entnext cur))
        )
      )
    )
  )
  found
)


(defun ddfd-room-vertices (en / ed typ cur vd pts pt elev flags item)
  (setq ed (entget en) typ (cdr (assoc 0 ed)) pts nil)
  (cond
    ((= typ "LWPOLYLINE")
     (setq elev (cond ((cdr (assoc 38 ed))) (T 0.0)))
     (foreach item ed
       (if (= (car item) 10)
         (progn (setq pt (cdr item))
           (setq pts (cons (trans (list (car pt) (cadr pt) elev) en 0) pts))))))
    ((= typ "POLYLINE")
     (setq flags (cond ((cdr (assoc 70 ed))) (T 0)))
     (if (= 0 (logand flags 88))
       (progn
         (setq cur (entnext en) elev (caddr (cdr (assoc 10 ed))))
         (if (not elev) (setq elev 0.0))
         (while (and cur (/= (cdr (assoc 0 (entget cur))) "SEQEND"))
           (setq vd (entget cur))
           (if (= (cdr (assoc 0 vd)) "VERTEX")
             (progn (setq pt (cdr (assoc 10 vd)))
               (setq pts (cons (trans (list (car pt) (cadr pt) elev) en 0) pts))))
           (setq cur (entnext cur)))))))
  (reverse pts))

(defun ddfd-room-closed-p (ename / ed pts)
  (setq ed (entget ename) pts (ddfd-room-vertices ename))
  (and (>= (length pts) 3)
       (or (= 1 (logand (cond ((cdr (assoc 70 ed))) (T 0)) 1))
           (equal (car pts) (last pts) 1e-6))))

(defun ddfd-export-one-room (fh en / ent layer floor name handle pts pt count)
  (setq ent (entget en) layer (cdr (assoc 8 ent)) floor (ddfd-layer-floor layer)
        name (ddfd-room-name en) handle (cdr (assoc 5 ent)))
  (if (or (not name) (= name "")) (setq name (strcat "房间_" handle)))
  (if (and (ddfd-room-closed-p en) (not (ddfd-room-has-arc en)))
    (progn
      (setq pts (ddfd-room-vertices en) count 0)
      (if (equal (car pts) (last pts) 1e-6)
        (setq pts (reverse (cdr (reverse pts)))))
      (foreach pt pts
        (setq count (1+ count))
        (ddfd-write-csv-row fh
          (list name floor (itoa count) (rtos (car pt) 2 6) (rtos (cadr pt) 2 6) layer handle)))
      count)))

;; 房间只认“定义房间”写过名称(XData)的多段线；图层上未命名的图形（图框、表格等）一律不当房间
(defun ddfd-room-entity-p (ename / ent)
  (setq ent (entget ename (list "DDFD_CABLE_ROOM")))
  (and (member (cdr (assoc 0 ent)) '("LWPOLYLINE" "POLYLINE"))
       (assoc -3 ent)))

;; 可导出的房间：模型空间、已命名、图层名能看出楼层、闭合、无圆弧、面积非零
(defun ddfd-room-exportable-p (ent / ed pts area prev pt)
  (and ent (setq ed (entget ent))
    (/= (cdr (assoc 67 ed)) 1)
    (ddfd-room-entity-p ent)
    (/= (ddfd-layer-floor (cdr (assoc 8 ed))) "")
    (ddfd-room-closed-p ent)
    (not (ddfd-room-has-arc ent))
    (progn
      (setq pts (ddfd-room-vertices ent) area 0.0 prev (last pts))
      (foreach pt pts
        (setq area (+ area (- (* (car prev) (cadr pt)) (* (car pt) (cadr prev)))) prev pt))
      (> (abs area) 1e-9))))

;; 扫描模型空间，返回 (房间图元表 CABLE_ROOM图层上未命名多段线句柄表 已命名但无效的句柄表)
;; 用 ssget 过滤让 CAD 自己按类型/图层/XData/空间筛选，不再 entnext 逐个遍历全图（大图里快很多）：
;;   第一次取带房间 XData 的多段线（不论图层），第二次取 CABLE_ROOM 图层上的多段线、跳过第一次已处理的；
;;   第二次仍会检查 XData，个别 CAD 不支持 XData 过滤时，房间图层上的已命名房间也不会漏掉
(defun ddfd-room-collect (/ named ss i ent ed rooms unnamed bad)
  (if (setq named (ssget "_X" '((0 . "*POLYLINE") (-4 . "<NOT") (67 . 1) (-4 . "NOT>")
                                (-3 ("DDFD_CABLE_ROOM")))))
    (progn
      (setq i 0)
      (repeat (sslength named)
        (setq ent (ssname named i) i (1+ i) ed (entget ent))
        (if (member (cdr (assoc 0 ed)) '("LWPOLYLINE" "POLYLINE"))
          (if (ddfd-room-exportable-p ent)
            (setq rooms (cons ent rooms))
            (setq bad (cons (cdr (assoc 5 ed)) bad)))))))
  (if (setq ss (ssget "_X" '((0 . "*POLYLINE") (8 . "CABLE_ROOM*") (-4 . "<NOT") (67 . 1) (-4 . "NOT>"))))
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq ent (ssname ss i) i (1+ i) ed (entget ent (list "DDFD_CABLE_ROOM")))
        (if (and (member (cdr (assoc 0 ed)) '("LWPOLYLINE" "POLYLINE"))
                 (not (and named (ssmemb ent named))))
          (cond
            ((not (assoc -3 ed)) (setq unnamed (cons (cdr (assoc 5 ed)) unnamed)))
            ((ddfd-room-exportable-p ent) (setq rooms (cons ent rooms)))
            (T (setq bad (cons (cdr (assoc 5 ed)) bad))))))))
  (list (reverse rooms) (reverse unnamed) (reverse bad)))

;; 在命令行按楼层列出要导出的房间，并提示同层重名、被跳过的多段线
(defun ddfd-room-report (info / key seen dup en)
  (princ (strcat "\n房间: " (itoa (length (car info))) " 个"))
  (foreach en (car info)
    (setq key (strcat (ddfd-layer-floor (cdr (assoc 8 (entget en)))) " " (ddfd-room-name en)))
    (princ (strcat "\n  " key))
    (if (member key seen) (setq dup (cons key dup)) (setq seen (cons key seen))))
  (foreach key dup
    (princ (strcat "\n注意：同层房间重名 " key "，统计时会忽略这些范围，请改名或删掉多余的一份。")))
  (if (cadr info)
    (princ (strcat "\n注意：CABLE_ROOM 图层上有 " (itoa (length (cadr info)))
                   " 个未命名多段线（不是用“定义房间”建的），不会导出。输入 DDFD_ROOM_CHECK 可定位查看。")))
  (if (caddr info)
    (princ (strcat "\n注意：有 " (itoa (length (caddr info)))
                   " 个已命名房间不闭合、含圆弧、面积为零或图层名看不出楼层，不会导出。输入 DDFD_ROOM_CHECK 可定位查看。")))
  (princ))

;; 把选择集缩放到可见范围（用 DXF 顶点算包围盒，不依赖 COM；临时关捕捉以免点被吸走）
(defun ddfd-room-zoom (ss / i pt x0 y0 x1 y1 d os)
  (setq i 0)
  (repeat (sslength ss)
    (foreach pt (ddfd-room-vertices (ssname ss i))
      (setq x0 (if x0 (min x0 (car pt)) (car pt))
            y0 (if y0 (min y0 (cadr pt)) (cadr pt))
            x1 (if x1 (max x1 (car pt)) (car pt))
            y1 (if y1 (max y1 (cadr pt)) (cadr pt))))
    (setq i (1+ i)))
  (if x0
    (progn
      (setq d (* 0.05 (max (- x1 x0) (- y1 y0) 1.0))
            os (getvar "OSMODE"))
      (setvar "OSMODE" 0)
      (command "_.ZOOM" "_W"
               (trans (list (- x0 d) (- y0 d) 0.0) 0 1)
               (trans (list (+ x1 d) (+ y1 d) 0.0) 0 1))
      (setvar "OSMODE" os))))

(defun ddfd-export-rooms (filename rooms / fh result en ok)
  (if (setq fh (open filename "w"))
    (progn
      (ddfd-write-csv-row fh (list "房间名称" "楼层" "顶点序号" "X" "Y" "图层" "句柄"))
      (setq ok T)
      (if (/= rooms 'NO-ROOMS)
        (foreach en rooms
          (setq result (vl-catch-all-apply 'ddfd-export-one-room (list fh en)))
          (if (vl-catch-all-error-p result)
            (progn
              (princ (strcat "\n房间导出错误: " (vl-catch-all-error-message result)))
              (setq ok nil))
            (if (not result) (setq ok nil)))))
      (close fh)
      ok)
    (progn (princ (strcat "\n无法写入文件: " filename)) nil)))

;; —— 导出统计 ——
;; ddfd-do-export 把 *ddfd-export-stats* 声明成局部变量，导出过程中往里记 (类别 . 内容)，成功后汇总打印

(defun ddfd-stat-add (key item)
  (setq *ddfd-export-stats* (cons (cons key item) *ddfd-export-stats*)))

(defun ddfd-stat-get (key / res pair)
  (foreach pair *ddfd-export-stats* (if (= (car pair) key) (setq res (cons (cdr pair) res))))
  res)

;; —— 柜子/竖井导出 ——

(defun ddfd-export-point-row (fh pattern en / ent layer floor handle kind pt nm)
  (setq ent (entget en)
        layer (cdr (assoc 8 ent))
        floor (ddfd-layer-floor layer)
        handle (cdr (assoc 5 ent))
        kind (if (wcmatch pattern "CABLE_SHAFT*") "SHAFT" "CAB")
        pt (ddfd-entity-point en)
        nm (ddfd-string-trim (ddfd-entity-name en)))
  (if (= kind "CAB")
    (setq nm (ddfd-remove-spaces nm))
  )
  (cond
    ((= nm "") (ddfd-stat-add (strcat kind "-EMPTY") handle))
    ((and pt (>= (length pt) 2))
     (if (= floor "") (ddfd-stat-add "NOFLOOR" layer))
     (ddfd-stat-add kind (list nm floor handle))
     (if (= kind "SHAFT")
       (ddfd-write-csv-row fh
         (list nm floor (rtos (car pt) 2 6) (rtos (cadr pt) 2 6) "" layer (cdr (assoc 0 ent)) handle))
       (ddfd-write-csv-row fh
         (list nm floor "" (rtos (car pt) 2 6) (rtos (cadr pt) 2 6) layer (cdr (assoc 0 ent)) handle))))))

;; 逐个图元捕获错误：先保证文件被关闭（否则 .pending 被锁、清理不掉），
;; 再报出出错图元的句柄；有任何图元失败就返回 nil，整次导出放弃、保留原数据
(defun ddfd-export-fail-message (en result)
  (princ (strcat "\n无法读取图元 " (cdr (assoc 5 (entget en))) " ("
                 (cdr (assoc 8 (entget en))) "): " (vl-catch-all-error-message result))))

;; ssget "_X" 也会选到布局（图纸空间，67 组码为 1）里的图元：模型空间和图纸空间分两次 ssget，
;; 由 CAD 直接过滤，图纸空间的只计数用于提示，不再逐个 entget 判断
(defun ddfd-model-ss (pattern)
  (ssget "_X" (list (cons 8 pattern) '(-4 . "<NOT") '(67 . 1) '(-4 . "NOT>"))))

(defun ddfd-count-paper (pattern / ss)
  (if (setq ss (ssget "_X" (list (cons 8 pattern) '(67 . 1))))
    (ddfd-stat-add "PAPER" (sslength ss))))

;; 逐个导出选择集里的图元，fn 的参数为 args 加上图元名；有图元出错就返回 nil（出错图元的句柄已打印）
(defun ddfd-export-ss (ss fn args / i en result ok)
  (setq ok T i 0)
  (if ss
    (repeat (sslength ss)
      (setq en (ssname ss i) i (1+ i)
            result (vl-catch-all-apply fn (append args (list en))))
      (if (vl-catch-all-error-p result) (progn (ddfd-export-fail-message en result) (setq ok nil)))))
  ok)

(defun ddfd-export-point-layer (pattern filename header / fh ok)
  (if (setq fh (open filename "w"))
    (progn
      (ddfd-write-csv-row fh header)
      (setq ok (ddfd-export-ss (ddfd-model-ss pattern) 'ddfd-export-point-row (list fh pattern)))
      (ddfd-count-paper pattern)
      (close fh)
      ok)
    (progn (princ (strcat "\n无法写入文件: " filename)) nil)))

;; —— 路径导出 ——

;; 凸度为 b 的圆弧段：圆心角 = 4*atan|b|，弧长 = 弦长*圆心角 / (2*sin(圆心角/2))；b 为 0 就是弦长
(defun ddfd-bulge-length (p1 p2 bulge / chord th)
  (setq chord (distance p1 p2))
  (if (and bulge (> (abs bulge) 1e-12) (> chord 0.0))
    (progn
      (setq th (* 4.0 (atan (abs bulge))))
      (/ (* chord th) (* 2.0 (sin (/ th 2.0)))))
    chord))

;; LWPOLYLINE 顶点：((WCS点 . 凸度) ...)；10 组码是 OCS 平面坐标，高程在 38 组码，凸度 42 组码跟在各自顶点后面
(defun ddfd-lwpoly-vertices (en ent / elev cur pts item)
  (setq elev (cond ((cdr (assoc 38 ent))) (T 0.0)))
  (foreach item ent
    (cond
      ((= (car item) 10)
       (if cur (setq pts (cons cur pts)))
       (setq cur (cons (trans (list (cadr item) (caddr item) elev) en 0) 0.0)))
      ((and cur (= (car item) 42))
       (setq cur (cons (car cur) (cdr item))))))
  (if cur (setq pts (cons cur pts)))
  (reverse pts))

;; 二维 POLYLINE：VERTEX 的 10 组码是 OCS（高程取 POLYLINE 自身 10 组码的 Z），凸度在 42 组码；
;; 三维多段线（70 组码含 8）的顶点就是 WCS、没有凸度；样条拟合的控制点（VERTEX 的 70 组码含 16）不在线上，跳过
(defun ddfd-poly-vertices (en ent / flags elev cur vd pt pts)
  (setq flags (cond ((cdr (assoc 70 ent))) (T 0))
        elev (cond ((caddr (cdr (assoc 10 ent)))) (T 0.0))
        cur (entnext en))
  (while (and cur (= (cdr (assoc 0 (setq vd (entget cur)))) "VERTEX"))
    (if (= 0 (logand (cond ((cdr (assoc 70 vd))) (T 0)) 16))
      (setq pt (cdr (assoc 10 vd))
            pts (cons (if (= 8 (logand flags 8))
                        (cons pt 0.0)
                        (cons (trans (list (car pt) (cadr pt) elev) en 0)
                              (cond ((cdr (assoc 42 vd))) (T 0.0))))
                      pts)))
    (setq cur (entnext cur)))
  (reverse pts))

;; 写一段路径；起点终点重合的段（重复顶点、整圆）跳过，段号仍按原顶点序号，与旧版一致
(defun ddfd-write-route-seg (fh routeid floor layer handle segno p1 p2 len)
  (if (> (distance p1 p2) 1e-9)
    (progn
      (ddfd-write-csv-row fh
        (list routeid floor
              (rtos (car p1) 2 6) (rtos (cadr p1) 2 6)
              (rtos (car p2) 2 6) (rtos (cadr p2) 2 6)
              (rtos (if len len (distance p1 p2)) 2 6) layer handle (itoa segno)))
      (setq *ddfd-seg-count* (1+ *ddfd-seg-count*)))))

;; 一个路径图元写成若干段：LINE 一段；ARC 一段（圆心、半径、起止角都在 OCS 里，逆时针从起点角到终点角）；
;; 多段线每段一行、段号 1..n，闭合的最后一段从末点回到首点；网格/多面网格和其他图元不导出，记下来导出后提示
(defun ddfd-export-route-rows (fh en / ent layer handle typ floor routeid flags cen r a0 a1 sweep verts k)
  (setq ent (entget en)
        layer (cdr (assoc 8 ent))
        handle (cdr (assoc 5 ent))
        typ (cdr (assoc 0 ent))
        floor (ddfd-layer-floor layer)
        routeid (strcat "R" handle)
        flags (cond ((cdr (assoc 70 ent))) (T 0)))
  (if (or (member typ '("LINE" "ARC" "LWPOLYLINE"))
          (and (= typ "POLYLINE") (= 0 (logand flags 80))))
    (progn
      (if (= floor "") (ddfd-stat-add "NOFLOOR" layer))
      (cond
        ((= typ "LINE")
         (ddfd-write-route-seg fh routeid floor layer handle 1
           (cdr (assoc 10 ent)) (cdr (assoc 11 ent)) nil))
        ((= typ "ARC")
         (setq cen (cdr (assoc 10 ent)) r (cdr (assoc 40 ent))
               a0 (cdr (assoc 50 ent)) a1 (cdr (assoc 51 ent))
               sweep (- a1 a0))
         (while (<= sweep 0.0) (setq sweep (+ sweep pi pi)))
         (ddfd-write-route-seg fh routeid floor layer handle 1
           (trans (list (+ (car cen) (* r (cos a0))) (+ (cadr cen) (* r (sin a0))) (caddr cen)) en 0)
           (trans (list (+ (car cen) (* r (cos a1))) (+ (cadr cen) (* r (sin a1))) (caddr cen)) en 0)
           (* r sweep)))
        (T
         (setq verts (if (= typ "LWPOLYLINE") (ddfd-lwpoly-vertices en ent) (ddfd-poly-vertices en ent)))
         (if (and (= 1 (logand flags 1)) (cdr verts))
           (setq verts (append verts (list (car verts)))))
         (setq k 1)
         (while (cdr verts)
           (ddfd-write-route-seg fh routeid floor layer handle k (caar verts) (caadr verts)
             (ddfd-bulge-length (caar verts) (caadr verts) (cdar verts)))
           (setq verts (cdr verts) k (1+ k))))))
    (ddfd-stat-add "UNSUPPORTED" (cons (if (= typ "POLYLINE") "POLYLINE网格" typ) handle))))

(defun ddfd-export-routes (filename / fh ok)
  (if (setq fh (open filename "w"))
    (progn
      (ddfd-write-csv-row fh (list "路径编号" "楼层" "起点X" "起点Y" "终点X" "终点Y" "长度_CAD单位" "图层" "句柄" "段号"))
      (setq ok (ddfd-export-ss (ddfd-model-ss "CABLE_ROUTE*") 'ddfd-export-route-rows (list fh)))
      (ddfd-count-paper "CABLE_ROUTE*")
      (close fh)
      ok)
    (progn (princ (strcat "\n无法写入文件: " filename)) nil)))

;; —— 导出汇总 ——

(defun ddfd-join (items sep / res s)
  (setq res (if items (car items) ""))
  (foreach s (cdr items) (setq res (strcat res sep s)))
  res)

;; 最多列出 limit 个，多了用省略号
(defun ddfd-join-limit (items sep limit / shown n s)
  (setq n 0)
  (foreach s items (if (< n limit) (setq shown (cons s shown))) (setq n (1+ n)))
  (strcat (ddfd-join (reverse shown) sep) (if (> n limit) (strcat sep "…") "")))

;; 计数：返回 ((项 . 个数) ...)，按首次出现的顺序
(defun ddfd-count-items (items / counts pair s)
  (foreach s items
    (if (setq pair (assoc s counts))
      (setq counts (subst (cons s (1+ (cdr pair))) pair counts))
      (setq counts (cons (cons s 1) counts))))
  (reverse counts))

;; 楼层排序键：地下室在前（B2F < B1F < 1F < 2F），楼层未知排最后
(defun ddfd-floor-key (fl)
  (cond ((= fl "") 1000)
        ((= (substr fl 1 1) "B") (- (atoi (substr fl 2))))
        (T (atoi fl))))

;; 导出成功后按文件报数量，再提示柜名重复、空柜名、不支持的路径图元、看不出楼层的图层、布局里的图元
;; 出现不止一次的名称，按名称排序、每个只列一次（区分大小写，与导出比较一致）。
;; 中望 2026 的 vl-sort 带 lambda 对大表极慢，这里用原生 acad_strlsort 排序：按不分大小写的同名分段，
;; 段内再用 member 找完全相同的；acad_strlsort 不可用时退回按出现次数计数
(defun ddfd-dup-names (names / sorted run key s nm res)
  (setq sorted (vl-catch-all-apply 'acad_strlsort (list names)))
  (if (or (vl-catch-all-error-p sorted) (/= (length sorted) (length names)))
    (foreach s (ddfd-count-items names) (if (> (cdr s) 1) (setq res (cons (car s) res))))
    (foreach s (append sorted (list nil))
      (if (and s run (= (strcase s) key))
        (setq run (cons s run))
        (progn
          (foreach nm (reverse run)
            (if (and (member nm (cdr (member nm run))) (not (member nm res)))
              (setq res (cons nm res))))
          (setq run (if s (list s)) key (if s (strcase s)))))))
  (reverse res))

(defun ddfd-export-summary (room-count / cabs floors prev run dups c empty unsup nofloor paper)
  (setq cabs (ddfd-stat-get "CAB")
        floors (vl-sort (ddfd-count-items (mapcar 'cadr cabs))
                        '(lambda (a b) (< (ddfd-floor-key (car a)) (ddfd-floor-key (car b))))))
  (princ (strcat "\n已导出四个CSV：柜子 " (itoa (length cabs)) " 个"
                 (if floors
                   (strcat "（"
                           (ddfd-join (mapcar '(lambda (p) (strcat (if (= (car p) "") "楼层未知" (car p)) " " (itoa (cdr p))))
                                              floors)
                                      " / ")
                           "）")
                   "")
                 "、路径线段 " (itoa *ddfd-seg-count*) " 段"
                 "、竖井 " (itoa (length (ddfd-stat-get "SHAFT"))) " 个"
                 "、房间 " (itoa room-count) " 个。"))
  ;; 柜名重复：每组的句柄按 CSV 顺序，第一个就是 Python 统计时采用的
  (foreach c (ddfd-dup-names (mapcar 'car cabs))
    (setq run nil)
    (foreach prev cabs (if (= (car prev) c) (setq run (cons (caddr prev) run))))
    (setq dups (cons (strcat c "（句柄 " (ddfd-join (reverse run) "、") "）") dups)))
  (if dups
    (princ (strcat "\n注意：柜名重复 " (itoa (length dups)) " 个，统计时只用每组第一个句柄的坐标，请改名或删掉多余的："
                   (ddfd-join-limit (reverse dups) "；" 10))))
  (if (setq empty (ddfd-stat-get "CAB-EMPTY"))
    (princ (strcat "\n注意：柜子图层上有 " (itoa (length empty))
                   " 个图元没有柜名（空文字、点或其他非文字图元），已跳过。句柄: " (ddfd-join-limit empty " " 20))))
  (if (setq empty (ddfd-stat-get "SHAFT-EMPTY"))
    (princ (strcat "\n注意：竖井图层上有 " (itoa (length empty))
                   " 个图元没有竖井编号，已跳过。句柄: " (ddfd-join-limit empty " " 20))))
  (if (setq unsup (ddfd-stat-get "UNSUPPORTED"))
    (princ (strcat "\n注意：CABLE_ROUTE 图层上有 " (itoa (length unsup)) " 个不支持的图元（"
                   (ddfd-join (mapcar 'car (ddfd-count-items (mapcar 'car unsup))) "、")
                   "），请炸开或改画多段线。句柄: " (ddfd-join-limit (mapcar 'cdr unsup) " " 20))))
  (if (setq nofloor (ddfd-count-items (ddfd-stat-get "NOFLOOR")))
    (princ (strcat "\n注意：这些图层名看不出楼层（应以 _1F、_B1F 这类结尾），导出的楼层列为空："
                   (ddfd-join (mapcar '(lambda (p) (strcat (car p) "（" (itoa (cdr p)) " 个图元）")) nofloor) "、"))))
  (if (setq paper (ddfd-stat-get "PAPER"))
    (princ (strcat "\n提示：布局（图纸空间）里有 " (itoa (apply '+ paper))
                   " 个 CABLE_* 图元，只导出模型空间的，已忽略。")))
  (princ))

;; 把 .pending 换成正式文件（outdir 末尾需带反斜杠）；任一步失败则回滚
(defun ddfd-export-commit (outdir / names fn dst bak tmp saved installed ok)
  (setq names '("柜子坐标.csv" "路径线段.csv" "竖井.csv" "房间范围.csv") ok T)
  ;; Refuse an unfinished previous transaction instead of overwriting its backup.
  (foreach fn names
    (if (findfile (strcat outdir fn ".previous"))
      (progn
        (setq ok nil)
        (princ (strcat "\n上次导出没有完成，留下了备份 " outdir fn ".previous；"
                       "请确认其中没有需要的数据后删除或改名，再重新导出。")))))
  (foreach fn names
    (if ok
      (progn
        (setq dst (strcat outdir fn) bak (strcat dst ".previous"))
        (if (findfile dst)
          (if (vl-file-rename dst bak) (setq saved (cons fn saved)) (setq ok nil))))))
  (foreach fn names
    (if ok
      (if (vl-file-rename (strcat outdir fn ".pending") (strcat outdir fn))
        (setq installed (cons fn installed)) (setq ok nil))))
  (if ok
    (foreach fn saved (vl-file-delete (strcat outdir fn ".previous")))
    (progn
      (foreach fn installed (vl-file-delete (strcat outdir fn)))
      (foreach fn saved
        (if (not (vl-file-rename (strcat outdir fn ".previous") (strcat outdir fn)))
          (princ (strcat "\n恢复失败，原文件保留在: " outdir fn ".previous"))))))
  ok)

(defun ddfd-export-stage (outdir rooms)
  (and (ddfd-export-rooms (strcat outdir "房间范围.csv.pending") rooms)
       (ddfd-export-point-layer "CABLE_CABINET*" (strcat outdir "柜子坐标.csv.pending")
         (list "柜子名称" "楼层" "房间" "X" "Y" "图层" "对象类型" "句柄"))
       (ddfd-export-routes (strcat outdir "路径线段.csv.pending"))
       (ddfd-export-point-layer "CABLE_SHAFT*" (strcat outdir "竖井.csv.pending")
         (list "竖井编号" "楼层" "X" "Y" "高度" "图层" "对象类型" "句柄"))))

;; 房间可以没有（导出空的 房间范围.csv）；房间列表在导出前打印，便于当场核对。
;; *ddfd-export-stats* 是局部变量（动态作用域），导出函数记下的数量只在本次导出里有效
(defun ddfd-do-export (outdir / info rooms result names fn *ddfd-export-stats* *ddfd-seg-count*)
  (setq *ddfd-seg-count* 0)
  (setq info (ddfd-room-collect))
  (ddfd-room-report info)
  (setq rooms (if (car info) (car info) 'NO-ROOMS))
  (if rooms
    (progn
      (setq result (vl-catch-all-apply 'ddfd-export-stage (list outdir rooms)))
      (if (and (not (vl-catch-all-error-p result)) result)
        (if (ddfd-export-commit outdir)
          (progn
            ;; 旧版本留下的房间范围记录已不再使用
            (if (findfile (strcat outdir "房间导出范围.txt"))
              (vl-file-delete (strcat outdir "房间导出范围.txt")))
            ;; 汇总只是提示，出错也不影响已经写好的文件
            (setq result (vl-catch-all-apply 'ddfd-export-summary
                           (list (if (= rooms 'NO-ROOMS) 0 (length rooms)))))
            (if (vl-catch-all-error-p result)
              (princ (strcat "\n已导出四个CSV（汇总提示出错: " (vl-catch-all-error-message result) "）")))
            T)
          (progn
            (princ "\n提交失败：请关闭正在用 Excel/WPS 打开的这几个CSV，或按上面的提示处理 .previous 备份后重试。")
            (foreach fn '("柜子坐标.csv" "路径线段.csv" "竖井.csv" "房间范围.csv")
              (if (findfile (strcat outdir fn ".pending"))
                (vl-file-delete (strcat outdir fn ".pending"))))
            nil))
        (progn
          (if (vl-catch-all-error-p result)
            (princ (strcat "\n导出阶段发生错误: " (vl-catch-all-error-message result)))
            (princ "\n有图元读取失败或文件无法写入（见上面的提示），本次没有覆盖项目数据。"))
          (setq names '("柜子坐标.csv" "路径线段.csv" "竖井.csv" "房间范围.csv"))
          (foreach fn names
            (if (findfile (strcat outdir fn ".pending"))
              (vl-file-delete (strcat outdir fn ".pending"))))
          nil)))
    (progn (princ "\n已取消导出，未覆盖项目数据。") nil)))

(defun c:DDFD_EXPORT_CABLE_ROUTE (/ prefix outdir)
  (setq prefix (getvar "DWGPREFIX"))
  (setq outdir (ddfd-clean-path (getstring T (strcat "\n导出目录 <" prefix "cable_export>: "))))
  (if (= outdir "")
    (setq outdir (strcat prefix "cable_export"))
  )
  (ddfd-ensure-folder outdir)
  (if (not (wcmatch outdir "*\\"))
    (setq outdir (strcat outdir "\\"))
  )
  (if (ddfd-do-export outdir)
    (progn
      (princ (strcat "\n已导出到：" outdir))
      (princ "\n请在网页版“电缆统计”中上传这四个CSV（桌面版则复制到项目 data 文件夹）。")))
  (princ)
)

;; 定位房间问题：选中并缩放到 CABLE_ROOM 图层上未命名、或已命名但无效的多段线（只选中，不修改图形）
(defun c:DDFD_ROOM_CHECK (/ info ss h en)
  (setq info (ddfd-room-collect))
  (ddfd-room-report info)
  (setq ss (ssadd))
  (foreach h (append (cadr info) (caddr info))
    (if (setq en (handent h)) (ssadd en ss)))
  (if (> (sslength ss) 0)
    (progn
      (princ "\n问题句柄:")
      (foreach h (append (cadr info) (caddr info)) (princ (strcat " " h)))
      (ddfd-room-zoom ss)
      (sssetfirst nil ss)
      (princ "\n已选中并缩放到这些多段线。图框/表格之类请在特性里改回原图层或删除；也可输入 DDFD_CLEAN_ROOM_LAYERS 把未命名的统一移到 0 层。"))
    (princ "\n房间图层没有问题图形。"))
  (princ))

;; 把 CABLE_ROOM 图层上未命名的多段线移到 0 层：先列出并确认，U 一步即可撤销
(defun c:DDFD_CLEAN_ROOM_LAYERS (/ info h en ed ans cnt)
  (setq info (ddfd-room-collect))
  (if (null (cadr info))
    (princ "\nCABLE_ROOM 图层上没有未命名的多段线。")
    (progn
      (princ (strcat "\n将把 " (itoa (length (cadr info))) " 个未命名多段线移到 0 层，句柄:"))
      (foreach h (cadr info) (princ (strcat " " h)))
      (initget "Y N")
      (setq ans (getkword "\n确认移动吗? [Y=是/N=否] <N>: "))
      (if (= ans "Y")
        (progn
          (command "_.UNDO" "_BE")
          (setq cnt 0)
          (foreach h (cadr info)
            (if (and (setq en (handent h)) (setq ed (entget en))
                     (entmod (subst (cons 8 "0") (assoc 8 ed) ed)))
              (setq cnt (1+ cnt))))
          (command "_.UNDO" "_E")
          (princ (strcat "\n已移动 " (itoa cnt) " 个到 0 层；移错了输入 U 撤销。")))
        (princ "\n已取消，未做任何修改。"))))
  (princ))

;;; ================= 引导向导部分 =================
;; 六步：1 建楼层 → 2 定义房间 → 3 标柜子 → 4 画通道 → 5 标竖井 → 6 检查导出。
;; 命令行向导和面板走同一套步骤函数：命令行不传楼层时现问，面板用 (ddfd:cabinets "2F") 这类函数直接指定楼层。

;; 楼层串 -> 图层名，kind 取 "CABINET" / "ROUTE" / "SHAFT" / "ROOM"
(defun ddfd-wiz-layer-name (kind floor)
  (strcat "CABLE_" kind "_" floor)
)

(defun ddfd-wiz-make-layer (name color)
  (if (not (tblsearch "LAYER" name))
    (entmake (list (cons 0 "LAYER")
                   (cons 100 "AcDbSymbolTableRecord")
                   (cons 100 "AcDbLayerTableRecord")
                   (cons 2 name)
                   (cons 70 0)
                   (cons 62 color)
                   (cons 6 "Continuous")))
  )
)

(defun ddfd-wiz-layer-color (kind)
  (cdr (assoc kind '(("CABINET" . 2) ("ROUTE" . 4) ("SHAFT" . 1) ("ROOM" . 6)))))

;; 确保某楼层的某类图层存在，返回图层名
(defun ddfd-wiz-ensure-layer (kind floor / nm)
  (setq nm (ddfd-wiz-layer-name kind floor))
  (ddfd-wiz-make-layer nm (ddfd-wiz-layer-color kind))
  nm)

;; 楼层很少，这里用 vl-sort 没有大列表的性能问题
(defun ddfd-wiz-sort-floors (floors)
  (vl-sort floors '(lambda (a b) (< (ddfd-floor-key a) (ddfd-floor-key b)))))

;; 图纸里已有的楼层：从 CABLE_* 图层名解析，按 B2F、B1F、1F、2F 排好
(defun ddfd-wiz-layer-floors (/ rec nm fl res)
  (setq rec (tblnext "LAYER" T))
  (while rec
    (setq nm (cdr (assoc 2 rec)))
    (if (wcmatch (strcase nm) "CABLE_CABINET*,CABLE_ROUTE*,CABLE_SHAFT*,CABLE_ROOM*")
      (progn
        (setq fl (ddfd-layer-floor nm))
        (if (and (/= fl "") (not (member fl res))) (setq res (cons fl res)))))
    (setq rec (tblnext "LAYER")))
  (ddfd-wiz-sort-floors res))

;; 手输楼层转成标准写法：1、1F、b1、B1F、二层 都能认；认不出返回 ""
(defun ddfd-wiz-parse-floor (s / fl)
  (setq s (ddfd-string-trim s))
  (if (= s "")
    ""
    (progn
      (setq fl (ddfd-layer-floor (strcat "_" s)))
      (if (= fl "") (setq fl (ddfd-layer-floor (strcat "_" s "F"))))
      fl)))

;; 按空格、逗号、顿号、分号拆开
(defun ddfd-wiz-split-floors (s / cur res c)
  (setq cur "")
  (foreach c (append (ddfd-string-chars s) (list " "))
    (if (member c '(" " "\t" "," "，" "、" ";" "；"))
      (progn
        (if (/= cur "") (setq res (cons cur res)))
        (setq cur ""))
      (setq cur (strcat cur c))))
  (reverse res))

;; "3" 表示 1F~3F；"B1F 1F 2F" 按列出的来。返回排好序、去重的楼层表，认不出的打印出来
(defun ddfd-wiz-input-floors (s / tokens n i fl res)
  (setq tokens (ddfd-wiz-split-floors s))
  (if (and tokens (null (cdr tokens))
           (> (setq n (atoi (car tokens))) 0)
           (= (itoa n) (car tokens)))
    (progn
      (setq i 1 n (min n 99))
      (while (<= i n)
        (setq res (cons (strcat (itoa i) "F") res) i (1+ i))))
    (foreach s tokens
      (setq fl (ddfd-wiz-parse-floor s))
      (cond
        ((= fl "") (princ (strcat "\n认不出楼层“" s "”，已跳过（应写 1F、2F、B1F 这样）。")))
        ((not (member fl res)) (setq res (cons fl res))))))
  (ddfd-wiz-sort-floors res))

;; 问一个楼层：回车用 def，认不出就重问
(defun ddfd-wiz-ask-one-floor (msg def / s fl)
  (setq fl "")
  (while (= fl "")
    (setq s (getstring T (strcat msg " <" def ">: ")))
    (if (= (ddfd-string-trim s) "")
      (setq fl def)
      (progn
        (setq fl (ddfd-wiz-parse-floor s))
        (if (= fl "") (princ "\n认不出这个楼层，请写 1F、2F、B1F 这样。")))))
  fl)

;; 选接下来要做的楼层。first 为 T 时回车用默认层；之后回车表示结束，返回 nil
(defun ddfd-wiz-ask-floor (first / floors def known s fl done)
  (setq floors (ddfd-wiz-layer-floors)
        def (cond ((member *ddfd-wiz-floor* floors) *ddfd-wiz-floor*)
                  ((car floors))
                  (T "1F"))
        known (if floors (strcat " 已有: " (ddfd-join floors " ")) ""))
  (while (not done)
    (setq s (ddfd-string-trim
              (getstring T (strcat "\n" (if first "处理哪一层?" "接着处理哪一层?") known
                                   (if first (strcat " <" def ">: ") " <回车结束>: ")))))
    (if (= s "")
      (setq fl (if first def) done T)
      (progn
        (setq fl (ddfd-wiz-parse-floor s))
        (if (= fl "")
          (princ "\n认不出这个楼层，请写 1F、2F、B1F 这样。")
          (setq done T)))))
  fl)

;; 对楼层执行 fn：传了 floor 只做这一层（面板用），没传就一层层问，想做哪层做哪层
(defun ddfd-wiz-each-floor (fn floor / cur first)
  (if floor
    (progn
      (setq *ddfd-wiz-floor* floor)
      (ddfd-ov-refresh)
      (apply fn (list floor)))
    (progn
      (setq first T)
      (while (setq cur (ddfd-wiz-ask-floor first))
        (setq first nil *ddfd-wiz-floor* cur)
        (ddfd-ov-refresh)
        (apply fn (list cur)))))
)

(defun ddfd-wiz-ask-text-height (/ def h)
  (setq def (cond (*ddfd-wiz-texth*) (T (getvar "TEXTSIZE"))))
  (if (<= def 0.0) (setq def 300.0))
  (setq h (getreal (strcat "\n标注文字高度(按图纸单位) <" (rtos def 2 1) ">: ")))
  (if (or (not h) (<= h 0.0)) (setq h def))
  (setq *ddfd-wiz-texth* h)
  h
)

;; 这张图问过字高就沿用，标柜子时输入 H 可以改
(defun ddfd-wiz-text-height ()
  (cond (*ddfd-wiz-texth*) (T (ddfd-wiz-ask-text-height))))

;; getpoint 返回的是当前 UCS 坐标，TEXT 的 10 组码要的是 WCS（默认拉伸方向下 OCS 就是 WCS），先转换，
;; 否则用了 UCS 的图里文字会跑到别处
(defun ddfd-wiz-make-text (pt h str layer)
  (entmake (list (cons 0 "TEXT")
                 (cons 8 layer)
                 (cons 10 (trans pt 1 0))
                 (cons 40 h)
                 (cons 1 str)
                 (cons 7 (getvar "TEXTSTYLE"))))
)

(defun ddfd-wiz-yesno (msg default / ans)
  (initget "Y N")
  (setq ans (getkword (strcat msg " [Y=是/N=否] <" default ">: ")))
  (if (not ans) (setq ans default))
  (= ans "Y")
)

;; —— 第1步：建楼层 ——
;; spec 是楼层文字（如 "B1F 1F 2F"），nil 时在命令行问；上次的输入记在注册表环境项里作默认值
(defun ddfd-wiz-step1 (spec / saved floors fl kind)
  (princ "\n———— 第1步：建楼层 ————")
  (princ "\n每层自动建 4 类图层：柜子(黄)、通道(青)、竖井(红)、房间(品红)。已存在的不会重建。")
  (if (not spec)
    (progn
      (setq saved (getenv "DDFD_CABLE_FLOORS"))
      (if (or (null saved) (= saved "")) (setq saved "2"))
      (setq spec (getstring T (strcat "\n这张图有哪些楼层（如 B1F 1F 2F；只输数字 3 表示 1F~3F）<" saved ">: ")))
      (if (= (ddfd-string-trim spec) "") (setq spec saved))))
  (setq floors (ddfd-wiz-input-floors spec))
  (if floors
    (progn
      (setenv "DDFD_CABLE_FLOORS" (ddfd-string-trim spec))
      (foreach fl floors
        (foreach kind '("CABINET" "ROUTE" "SHAFT" "ROOM")
          (ddfd-wiz-ensure-layer kind fl)))
      (setq *ddfd-wiz-floor* (car floors))
      (princ (strcat "\n楼层就绪：" (ddfd-join floors " ") "。")))
    (princ "\n没有可用的楼层，未创建图层。"))
  (princ)
)

;; 查找某楼层房间图层上已使用该名称的房间（排除 self），返回图元名或 nil
(defun ddfd-wiz-find-room (layer nm self / ss i en found)
  (if (setq ss (ssget "_X" (list '(0 . "*POLYLINE") (cons 8 layer))))
    (progn
      (setq i 0)
      (while (and (not found) (< i (sslength ss)))
        (setq en (ssname ss i) i (1+ i))
        (if (and (not (equal en self)) (= (ddfd-room-name en) nm))
          (setq found en)))))
  found)

;; 有的 AutoCAD 没有 vlax 函数，复制和改属性都走 DXF 数据
(defun ddfd-wiz-strip-ent (ed layer)
  (subst (cons 8 layer) (assoc 8 ed)
         (vl-remove-if '(lambda (p) (member (car p) '(-1 5 102 330 360))) ed)))

;; 复制一条多段线到 layer，返回新图元；POLYLINE 要连顶点和 SEQEND 一起建
(defun ddfd-wiz-copy-to-layer (en layer / ed sub)
  (setq ed (entget en))
  (if (entmake (ddfd-wiz-strip-ent ed layer))
    (progn
      (if (= (cdr (assoc 0 ed)) "POLYLINE")
        (progn
          (setq sub (entnext en))
          (while sub
            (setq ed (entget sub))
            (entmake (ddfd-wiz-strip-ent ed layer))
            (setq sub (if (= (cdr (assoc 0 ed)) "SEQEND") nil (entnext sub))))))
      (entlast))))

;; 设上闭合标志并放到房间图层
(defun ddfd-wiz-room-close (en layer / ed flag)
  (setq ed (entget en)
        flag (cond ((cdr (assoc 70 ed))) (T 0))
        ed (subst (cons 8 layer) (assoc 8 ed) ed))
  (entmod (subst (cons 70 (logior flag 1)) (assoc 70 ed) ed)))

;; —— 第2步：定义房间，给闭合直线多段线写房间名称 ——
;; 普通图层上的多段线复制一份到 CABLE_ROOM_nF 再命名（原图形不动）；
;; 已是房间或本来就画在房间图层上的，直接原地命名/改名，避免叠出重复的房间。
;; 不切换当前图层，之后画的图形不会误落到房间图层上。
(defun ddfd-wiz-rooms-floor (floor / layer pick en ent typ old nm dupe target cnt)
  (setq layer (ddfd-wiz-ensure-layer "ROOM" floor))
  (setq cnt 0)
  (setq pick (entsel (strcat "\n[" floor "] 选择闭合多段线（回车结束）: ")))
  (while pick
    (setq en (car pick))
    (setq ent (entget en))
    (setq typ (cdr (assoc 0 ent)))
    (cond
      ((not (member typ '("LWPOLYLINE" "POLYLINE")))
       (princ "\n对象不是 LWPOLYLINE/POLYLINE，已跳过。"))
      ((not (ddfd-room-closed-p en))
       (princ "\n多段线既未设置闭合标志，首尾点也未重合，已跳过。"))
      ((ddfd-room-has-arc en)
       (princ "\n房间范围不能包含圆弧段，请改用直线多段线。"))
      (T
       (setq old (ddfd-room-name en))
       (if (/= old "")
         (princ (strcat "\n这已经是房间「" old "」，输入新名称可改名，直接回车保持不变。")))
       (setq nm (getstring T "\n输入房间名称: "))
       (setq dupe (if (/= nm "") (ddfd-wiz-find-room layer nm en)))
       (cond
         ((= nm "")
          (princ (if (/= old "") "\n未改名。" "\n房间名称不能为空，已跳过。")))
         ((and dupe
               (not (ddfd-wiz-yesno (strcat "\n" floor " 已有房间「" nm "」，删掉旧的、用这次选的替换吗?") "N")))
          (princ "\n已跳过，原来的房间保持不变。"))
         (T
          (if dupe (entdel dupe))
          (if (or (/= old "") (wcmatch (strcase (cdr (assoc 8 ent))) "CABLE_ROOM*"))
            (setq target en)
            (setq target (ddfd-wiz-copy-to-layer en layer)))
          (ddfd-wiz-room-close target layer)
          (ddfd-room-set-name target nm)
          (setq cnt (1+ cnt))
          (princ (strcat "\n已定义房间：" nm))
          (ddfd-ov-refresh)))))
    (setq pick (entsel (strcat "\n[" floor "] 选择下一个闭合多段线（回车结束）: ")))
  )
  (princ (strcat "\n" floor " 本次定义 " (itoa cnt) " 个房间。"))
)

(defun ddfd-wiz-step2 (floor)
  (princ "\n———— 第2步：定义房间 ————")
  (princ "\n逐个选择已闭合的直线多段线，输入房间名称。普通图层上的图形会复制一份到房间图层，原图形不动。")
  (ddfd-wiz-each-floor 'ddfd-wiz-rooms-floor floor)
  (princ)
)

;; 柜名索引：模型空间柜子图层上全部图元的 ((去空格柜名 句柄 图层) ...)。第3步开始时建一次，
;; 之后每标一个就追加一条，不用每点一次都把全部柜子重新读一遍（柜子多时明显变快）
(defun ddfd-wiz-cabinet-index (/ ss i en ed res)
  (if (setq ss (ddfd-model-ss "CABLE_CABINET*"))
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq en (ssname ss i) ed (entget en) i (1+ i)
              res (cons (list (ddfd-remove-spaces (ddfd-entity-name en)) (cdr (assoc 5 ed)) (cdr (assoc 8 ed)))
                        res)))))
  (reverse res))

(defun ddfd-wiz-cabinet-key (nm) (ddfd-remove-spaces (ddfd-text-plain nm)))

;; 索引里已经用了这个柜名、且图元还在（没被删掉）的，返回 ((句柄 . 图层) ...)；比较时和导出一样按去掉空格后的柜名
(defun ddfd-wiz-find-cabinet (nm idx / key e en res)
  (setq key (ddfd-wiz-cabinet-key nm))
  (if (/= key "")
    (foreach e idx
      (if (and (= key (car e)) (setq en (handent (cadr e))) (entget en))
        (setq res (cons (cons (cadr e) (caddr e)) res)))))
  (reverse res))

(defun ddfd-wiz-cabinet-point (floor msg)
  (initget "H")
  (getpoint (strcat "\n[" floor "] " msg " [H=改字高] <回车结束本层>: ")))

;; h、idx 是 ddfd-wiz-step3 的局部变量，动态作用域下这里直接读写
(defun ddfd-wiz-cabinets-floor (floor / layer pt nm dupe cnt)
  (setq layer (ddfd-wiz-ensure-layer "CABINET" floor))
  (setvar "CLAYER" layer)
  (setq cnt 0)
  (setq pt (ddfd-wiz-cabinet-point floor "指定柜子出线点"))
  (while pt
    (if (= (type pt) 'STR)
      (setq h (ddfd-wiz-ask-text-height))
      (progn
        (setq nm (getstring T "柜子名称: "))
        (cond
          ((= (ddfd-string-trim nm) "")
           (princ "  柜名为空，本点作废。"))
          ((and (setq dupe (ddfd-wiz-find-cabinet nm idx))
                (not (ddfd-wiz-yesno
                       (strcat "\n柜名「" nm "」已经标过（" (cdar dupe) " 句柄 " (caar dupe)
                               (if (cdr dupe) (strcat " 等 " (itoa (length dupe)) " 处") "")
                               "），再标会重名，统计时只会用其中一个的位置。仍然标注吗?")
                       "N")))
           (princ "  已跳过，本点作废。"))
          ((ddfd-wiz-make-text pt h nm layer)
           (setq cnt (1+ cnt)
                 idx (cons (list (ddfd-wiz-cabinet-key nm) (cdr (assoc 5 (entget (entlast)))) layer) idx))
           (princ (strcat "  已标注: " nm))
           (ddfd-ov-refresh))
          (T (princ "  文字创建失败（请检查当前文字样式和图层是否锁定），本点作废。")))))
    (setq pt (ddfd-wiz-cabinet-point floor "指定下一个柜子出线点"))
  )
  (princ (strcat "\n" floor " 本次标注 " (itoa cnt) " 个柜子。"))
)

;; —— 第3步：标柜子出线点 ——
(defun ddfd-wiz-step3 (floor / h idx)
  (princ "\n———— 第3步：标柜子 ————")
  (princ "\n在每个柜子的“柜后出线点”位置点一下，再输入柜名。")
  (princ "\n柜名要和 Excel 清册的 起点/终点 写得一样（空格差异不用管，程序自动忽略）。")
  (setq h (ddfd-wiz-text-height))
  (setq idx (ddfd-wiz-cabinet-index))
  (ddfd-wiz-each-floor 'ddfd-wiz-cabinets-floor floor)
  (princ "\n标错的直接用 ERASE 删掉那个文字再重标即可。")
  (princ)
)

(defun ddfd-wiz-routes-floor (floor / layer more)
  (setq layer (ddfd-wiz-ensure-layer "ROUTE" floor))
  (setvar "CLAYER" layer)
  (setq more T)
  (while more
    (princ (strcat "\n[" floor "] 开始画一条通道(多段线)，画完回车结束这条线..."))
    (command "_.PLINE")
    (while (> (getvar "CMDACTIVE") 0) (command PAUSE))
    (ddfd-ov-refresh)
    (setq more (ddfd-wiz-yesno (strcat "\n[" floor "] 继续画下一条通道?") "Y"))
  )
)

;; —— 第4步：画通道 ——
(defun ddfd-wiz-step4 (floor)
  (princ "\n———— 第4步：画通道 ————")
  (princ "\n沿电缆沟/桥架的中心线画多段线，电缆能走哪里线就画到哪里。")
  (princ "\n关键：两条线相接时端点必须真正搭上（端点对端点，或端点搭在另一条线上），只是看着交叉不算连通。")
  (princ "\n已自动打开 端点/交点/最近点 捕捉，照着捕捉标记点取点即可。")
  (setvar "OSMODE" 545)
  (ddfd-wiz-each-floor 'ddfd-wiz-routes-floor floor)
  (princ)
)

;; r 是倒序的字符表：去掉尾部的数字
(defun ddfd-wiz-strip-digits (r)
  (while (ddfd-digit-p (car r)) (setq r (cdr r)))
  r)

;; 去掉编号和楼层后缀之间的分隔符
(defun ddfd-wiz-strip-seps (r)
  (while (member (car r) '("_" "-" " " "\t")) (setq r (cdr r)))
  r)

;; 倒序字符表去掉楼层后缀：1F、B1F、B1、F1、二层、地下一层、负一层
(defun ddfd-wiz-strip-floor-tail (r / s)
  (cond
    ((member (car r) '("F" "f"))
     (setq s (ddfd-wiz-strip-digits (cdr r)))
     (cond
       ((= (length s) (length (cdr r))) r)
       ((member (car s) '("B" "b")) (ddfd-wiz-strip-seps (cdr s)))
       (T (ddfd-wiz-strip-seps s))))
    ((ddfd-digit-p (car r))
     (setq s (ddfd-wiz-strip-digits r))
     (if (member (car s) '("B" "b" "F" "f"))
       (ddfd-wiz-strip-seps (cdr s))
       r))
    ((member (car r) '("层" "楼"))
     (setq s (cdr r))
     (while (and (car s) (ddfd-cn-digit (car s))) (setq s (cdr s)))
     (cond
       ((= (length s) (length (cdr r))) r)
       ((equal (car s) "负") (cdr s))
       ((and (equal (car s) "下") (equal (cadr s) "地")) (cddr s))
       (T s)))
    (T r)))

;; 竖井配对名：ZJ1_1F、ZJ1-2F、ZJ1_B1F、竖井甲二层 → ZJ1、竖井甲（和网页的 normalize_shaft_base_id 一致）
;; 按字处理（MBCS 下汉字尾字节可能就是 "_" 的编码）
(defun ddfd-wiz-shaft-base (nm / res)
  (setq res (apply 'strcat (reverse (ddfd-wiz-strip-floor-tail
                                      (reverse (ddfd-string-chars (ddfd-string-trim nm)))))))
  (if (= res "") "竖井" res))

;; 图上已有竖井编号的表，用于默认编号和重名提醒
(defun ddfd-wiz-shaft-names (/ ss i nm res)
  (if (setq ss (ddfd-model-ss "CABLE_SHAFT*"))
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq nm (ddfd-string-trim (ddfd-entity-name (ssname ss i))) i (1+ i))
        (if (/= nm "")
          (progn
            (setq nm (strcase (ddfd-wiz-shaft-base nm)))
            (if (not (member nm res)) (setq res (cons nm res))))))))
  res)

;; 下一个可用的 ZJ 编号：图上已有 ZJ1~ZJn 时从 n+1 开始，重新加载 LISP 后也不会从 ZJ1 重来
(defun ddfd-wiz-next-shaft-no (names / nm best)
  (setq best 0)
  (foreach nm names
    (if (wcmatch nm "ZJ#*") (setq best (max best (atoi (substr nm 3))))))
  (1+ best))

;; a、b 之间（含两端）的楼层，从低到高；a、b 不在 floors 里也算上
(defun ddfd-wiz-floor-range (floors a b / lo hi fl res)
  (setq lo (min (ddfd-floor-key a) (ddfd-floor-key b))
        hi (max (ddfd-floor-key a) (ddfd-floor-key b)))
  (foreach fl (append floors (list a b))
    (if (and (<= lo (ddfd-floor-key fl) hi) (not (member fl res)))
      (setq res (cons fl res))))
  (ddfd-wiz-sort-floors res))

;; —— 第5步：标竖井 ——
(defun ddfd-wiz-step5 (/ floors h base a b f layer pt more names)
  (princ "\n———— 第5步：标竖井（有跨楼层电缆才需要）————")
  (setq floors (ddfd-wiz-layer-floors))
  (if (< (length floors) 2)
    (princ "\n只有一层楼，用不到竖井，本步跳过。")
    (progn
      (princ "\n同一个竖井要在它经过的每一层平面图上各点一个位置，程序会自动写 ZJn_楼层 配对文字。")
      (setq h (ddfd-wiz-text-height))
      (setq names (ddfd-wiz-shaft-names))
      (setq *ddfd-wiz-shaftn* (max (cond (*ddfd-wiz-shaftn*) (T 1)) (ddfd-wiz-next-shaft-no names)))
      (setq more T)
      (while more
        (setq base (ddfd-string-trim (getstring (strcat "\n竖井编号 <ZJ" (itoa *ddfd-wiz-shaftn*) ">: "))))
        (if (= base "") (setq base (strcat "ZJ" (itoa *ddfd-wiz-shaftn*))))
        (if (and (member (strcase base) names)
                 (not (ddfd-wiz-yesno (strcat "\n图上已有竖井 " base "，继续标会和它配到一起。仍然用这个编号吗?") "N")))
          (progn
            (setq *ddfd-wiz-shaftn* (ddfd-wiz-next-shaft-no names)
                  base (strcat "ZJ" (itoa *ddfd-wiz-shaftn*)))
            (princ (strcat "\n改用新编号 " base "。"))))
        (setq names (cons (strcase base) names))
        (setq a (ddfd-wiz-ask-one-floor "\n这个竖井从哪层开始?" (car floors)))
        (setq b (ddfd-wiz-ask-one-floor "\n到哪层结束?" (last floors)))
        (foreach f (ddfd-wiz-floor-range floors a b)
          (setq layer (ddfd-wiz-ensure-layer "SHAFT" f))
          (setvar "CLAYER" layer)
          (setq *ddfd-wiz-floor* f)
          (ddfd-ov-refresh)
          (setq pt (getpoint (strcat "\n在 " f " 平面图上点竖井 " base " 的位置: ")))
          (if pt
            (progn
              (ddfd-wiz-make-text pt h (strcat base "_" f) layer)
              (princ (strcat "  已标注: " base "_" f))
              (ddfd-ov-refresh))
            (princ (strcat "  跳过 " f "（注意：竖井没配对会在问题清单里提示）。"))))
        (setq *ddfd-wiz-shaftn* (ddfd-wiz-next-shaft-no names))
        (setq more (ddfd-wiz-yesno "\n还要添加下一个竖井吗?" "N")))))
  (princ)
)

;;; ================= 定义总览 =================
;; 读图纸里已定义的全部内容，算好归属和问题，存进下面这些全局表，命令行和面板都从这里取：
;;   *ddfd-ov-floors*  楼层串的表，楼层未知的对象归到 ""，排在最后
;;   *ddfd-ov-rooms*   ((楼层 名称 句柄 顶点表 (x0 y0 x1 y1)) ...)
;;   *ddfd-ov-cabs*    ((柜名 楼层 句柄 x y 房间句柄或nil 房间名或"") ...)
;;   *ddfd-ov-shafts*  ((配对名 全名 楼层 句柄 x y) ...)
;;   *ddfd-ov-routes*  ((楼层 句柄 段数 顶点表) ...)
;;   *ddfd-ov-issues*  ((级别 步骤号 类别 句柄 文字) ...)，级别 err 错误、warn 提醒、info 说明
;; 只读图纸，不修改任何对象。

(defun ddfd-ov-issue (level step kind handle text)
  (setq *ddfd-ov-issues* (cons (list level step kind handle text) *ddfd-ov-issues*)))

(defun ddfd-ov-bbox (pts / p x0 y0 x1 y1)
  (foreach p pts
    (setq x0 (if x0 (min x0 (car p)) (car p))
          y0 (if y0 (min y0 (cadr p)) (cadr p))
          x1 (if x1 (max x1 (car p)) (car p))
          y1 (if y1 (max y1 (cadr p)) (cadr p))))
  (list x0 y0 x1 y1))

;; 点在线段上（和网页 point_on_segment 相同的判定）
(defun ddfd-ov-on-seg (x y a b / ax ay bx by scale)
  (setq ax (car a) ay (cadr a) bx (car b) by (cadr b)
        scale (max 1.0 (distance (list ax ay) (list bx by))))
  (and (<= (abs (- (* (- x ax) (- by ay)) (* (- y ay) (- bx ax)))) (* 1e-8 scale))
       (<= (+ (* (- x ax) (- x bx)) (* (- y ay) (- y by))) (* 1e-8 scale))))

;; 点在多边形内，边界上也算（和网页 point_in_polygon 相同的判定）
(defun ddfd-ov-in-poly (x y pts / prev p ay by on inside)
  (setq prev (last pts))
  (foreach p pts
    (if (not on)
      (progn
        (if (ddfd-ov-on-seg x y prev p)
          (setq on T)
          (progn
            (setq ay (cadr prev) by (cadr p))
            (if (and (not (eq (> ay y) (> by y)))
                     (> (+ (car prev) (/ (* (- y ay) (- (car p) (car prev))) (- by ay))) x))
              (setq inside (not inside)))))
        (setq prev p))))
  (or on inside))

;; 同楼层、点在范围内的房间记录
(defun ddfd-ov-rooms-at (floor x y / r box res)
  (foreach r *ddfd-ov-rooms*
    (setq box (nth 4 r))
    (if (and (= (car r) floor)
             (<= (car box) x (caddr box))
             (<= (cadr box) y (cadddr box))
             (ddfd-ov-in-poly x y (nth 3 r)))
      (setq res (cons r res))))
  (reverse res))

(defun ddfd-ov-room-record (en / ed pts)
  (setq ed (entget en) pts (ddfd-room-vertices en))
  (if (equal (car pts) (last pts) 1e-6)
    (setq pts (reverse (cdr (reverse pts)))))
  (list (ddfd-layer-floor (cdr (assoc 8 ed))) (ddfd-room-name en) (cdr (assoc 5 ed)) pts (ddfd-ov-bbox pts)))

(defun ddfd-ov-add-cab (en / ent layer floor handle pt nm hits)
  (setq ent (entget en)
        layer (cdr (assoc 8 ent))
        floor (ddfd-layer-floor layer)
        handle (cdr (assoc 5 ent))
        pt (ddfd-entity-point en)
        nm (ddfd-remove-spaces (ddfd-string-trim (ddfd-entity-name en))))
  (cond
    ((= nm "")
     (ddfd-ov-issue "err" 3 "柜名为空" handle (strcat "柜子图层上有对象没有柜名（" layer "），不会被导出")))
    ((and pt (>= (length pt) 2))
     (if (= floor "")
       (ddfd-ov-issue "err" 3 "楼层未知" handle (strcat "柜子 " nm " 所在图层看不出楼层：" layer)))
     (setq hits (ddfd-ov-rooms-at floor (car pt) (cadr pt)))
     (if (cdr hits)
       (ddfd-ov-issue "warn" 3 "房间重叠" handle
         (strcat "柜子 " nm " 同时在多个房间内：" (ddfd-join (mapcar 'cadr hits) "、"))))
     (setq *ddfd-ov-cabs*
       (cons (list nm floor handle (car pt) (cadr pt)
                   (if hits (caddr (car hits)))
                   (if hits (cadr (car hits)) ""))
             *ddfd-ov-cabs*)))))

(defun ddfd-ov-add-shaft (en / ent layer floor handle pt nm)
  (setq ent (entget en)
        layer (cdr (assoc 8 ent))
        floor (ddfd-layer-floor layer)
        handle (cdr (assoc 5 ent))
        pt (ddfd-entity-point en)
        nm (ddfd-string-trim (ddfd-entity-name en)))
  (cond
    ((= nm "")
     (ddfd-ov-issue "err" 5 "竖井名为空" handle (strcat "竖井图层上有对象没有编号（" layer "），不会被导出")))
    ((and pt (>= (length pt) 2))
     (if (= floor "")
       (ddfd-ov-issue "err" 5 "楼层未知" handle (strcat "竖井 " nm " 所在图层看不出楼层：" layer)))
     (setq *ddfd-ov-shafts*
       (cons (list (ddfd-wiz-shaft-base nm) nm floor handle (car pt) (cadr pt)) *ddfd-ov-shafts*)))))

;; 通道的顶点表（WCS），规则和 ddfd-export-route-rows 一样；不支持的图元返回 nil
(defun ddfd-ov-route-points (en ent / typ flags cen r a0 a1 sweep res)
  (setq typ (cdr (assoc 0 ent))
        flags (cond ((cdr (assoc 70 ent))) (T 0)))
  (cond
    ((= typ "LINE") (list (cdr (assoc 10 ent)) (cdr (assoc 11 ent))))
    ((= typ "ARC")
     (setq cen (cdr (assoc 10 ent)) r (cdr (assoc 40 ent))
           a0 (cdr (assoc 50 ent)) a1 (cdr (assoc 51 ent))
           sweep (- a1 a0))
     (while (<= sweep 0.0) (setq sweep (+ sweep pi pi)))
     (mapcar '(lambda (a)
                (trans (list (+ (car cen) (* r (cos a))) (+ (cadr cen) (* r (sin a))) (caddr cen)) en 0))
             (list a0 (+ a0 (/ sweep 4.0)) (+ a0 (/ sweep 2.0)) (+ a0 (* 0.75 sweep)) (+ a0 sweep))))
    ((or (= typ "LWPOLYLINE") (and (= typ "POLYLINE") (= 0 (logand flags 80))))
     (setq res (mapcar 'car (if (= typ "LWPOLYLINE") (ddfd-lwpoly-vertices en ent) (ddfd-poly-vertices en ent))))
     (if (and (= 1 (logand flags 1)) (cdr res))
       (append res (list (car res)))
       res))))

;; 段数按导出写出的行数算：首尾重合的段不算；圆弧导出时是一段，这里顶点多只是为了画图
(defun ddfd-ov-route-segs (typ pts / n)
  (setq n 0)
  (if (= typ "ARC")
    1
    (progn
      (while (cdr pts)
        (if (> (distance (car pts) (cadr pts)) 1e-9) (setq n (1+ n)))
        (setq pts (cdr pts)))
      n)))

(defun ddfd-ov-add-route (en / ent layer floor handle typ pts)
  (setq ent (entget en)
        layer (cdr (assoc 8 ent))
        floor (ddfd-layer-floor layer)
        handle (cdr (assoc 5 ent))
        typ (cdr (assoc 0 ent))
        pts (ddfd-ov-route-points en ent))
  (if pts
    (progn
      (if (= floor "")
        (ddfd-ov-issue "err" 4 "楼层未知" handle (strcat "通道所在图层看不出楼层：" layer)))
      (setq *ddfd-ov-routes* (cons (list floor handle (ddfd-ov-route-segs typ pts) pts) *ddfd-ov-routes*)))
    (ddfd-ov-issue "err" 4 "不支持的图元" handle
      (strcat "通道图层上的 " (if (= typ "POLYLINE") "POLYLINE变体" typ) " 不会被导出，请炸开或改成多段线"))))

;; 柜子、通道都画了才算这一层能算；有柜子没通道的楼层要提醒
(defun ddfd-ov-floor-check (fl / cabs routes)
  (setq cabs (ddfd-ov-floor-items *ddfd-ov-cabs* 1 fl)
        routes (ddfd-ov-floor-items *ddfd-ov-routes* 0 fl))
  (if (and cabs (null routes) (/= fl ""))
    (ddfd-ov-issue "warn" 4 "缺通道" "" (strcat fl " 有柜子但没有通道"))))

;; 表里第 idx 项等于楼层 fl 的记录
(defun ddfd-ov-floor-items (lst idx fl)
  (vl-remove-if-not '(lambda (r) (equal (nth idx r) fl)) lst))

(defun ddfd-ov-check-rooms (/ seen key r)
  (foreach r *ddfd-ov-rooms*
    (setq key (strcat (car r) " " (cadr r)))
    (if (member key seen)
      (ddfd-ov-issue "warn" 2 "房间重名" (caddr r) (strcat "同层房间重名：" key))
      (setq seen (cons key seen)))
    (if (null (ddfd-ov-room-cabs (caddr r)))
      (ddfd-ov-issue "info" 2 "空房间" (caddr r) (strcat "房间 " key " 里没有柜子")))))

;; 房间里的柜子记录
(defun ddfd-ov-room-cabs (handle)
  (ddfd-ov-floor-items *ddfd-ov-cabs* 5 handle))

;; 重名柜子：第一处是统计时会用的位置，后面每一处各列一条，点击能定位
(defun ddfd-ov-check-dups (/ c hits n i r)
  ;; AutoCAD 的 acad_strlsort 遇到空表会打印用法，没柜子时不调用
  (foreach c (if *ddfd-ov-cabs* (ddfd-dup-names (mapcar 'car *ddfd-ov-cabs*)))
    (setq hits (ddfd-ov-floor-items *ddfd-ov-cabs* 0 c) n (length hits) i 1)
    (foreach r (cdr hits)
      (setq i (1+ i))
      (ddfd-ov-issue "err" 3 "柜名重复" (caddr r)
        (strcat "柜名 " c " 重复 " (itoa n) " 处，这是第 " (itoa i) " 处；统计时只用第 1 处")))))

;; 竖井只标了一层就配不成对
(defun ddfd-ov-check-shafts (/ bases b s floors)
  (foreach s *ddfd-ov-shafts*
    (if (not (member (car s) bases)) (setq bases (cons (car s) bases))))
  (foreach b (reverse bases)
    (setq floors nil)
    (foreach s *ddfd-ov-shafts*
      (if (= (car s) b)
        (if (member (caddr s) floors)
          (ddfd-ov-issue "warn" 5 "竖井重复" (cadddr s) (strcat "竖井 " b " 在 " (caddr s) " 标了不止一处"))
          (setq floors (cons (caddr s) floors)))))
    (if (null (cdr floors))
      (ddfd-ov-issue "warn" 5 "竖井未配对" (cadddr (car (ddfd-ov-floor-items *ddfd-ov-shafts* 0 b)))
        (strcat "竖井 " b " 只标了 " (car floors) "，没有配对的楼层")))))

;; 布局里的 CABLE_* 图元不会被导出，提示一下
(defun ddfd-ov-check-paper (/ ss)
  (if (setq ss (ssget "_X" '((8 . "CABLE_CABINET*,CABLE_ROUTE*,CABLE_SHAFT*") (67 . 1))))
    (ddfd-ov-issue "info" 6 "布局图元" ""
      (strcat "布局（图纸空间）里有 " (itoa (sslength ss)) " 个 CABLE_* 图元，只导出模型空间，已忽略"))))

;; 重新读一遍图纸。房间先读，柜子归属要用
(defun ddfd-ov-collect (/ info en h fl floors)
  (setq *ddfd-ov-rooms* nil *ddfd-ov-cabs* nil *ddfd-ov-shafts* nil *ddfd-ov-routes* nil *ddfd-ov-issues* nil)
  (setq info (ddfd-room-collect))
  (foreach en (car info)
    (setq *ddfd-ov-rooms* (cons (ddfd-ov-room-record en) *ddfd-ov-rooms*)))
  (setq *ddfd-ov-rooms* (reverse *ddfd-ov-rooms*))
  (foreach h (cadr info)
    (ddfd-ov-issue "warn" 2 "未命名房间" h "房间图层上这条多段线没有名称，不会算作房间"))
  (foreach h (caddr info)
    (ddfd-ov-issue "warn" 2 "无效房间" h "这个房间不闭合、含圆弧、面积为零或图层看不出楼层，不会被导出"))
  (ddfd-export-ss (ddfd-model-ss "CABLE_CABINET*") 'ddfd-ov-add-cab nil)
  (ddfd-export-ss (ddfd-model-ss "CABLE_SHAFT*") 'ddfd-ov-add-shaft nil)
  (ddfd-export-ss (ddfd-model-ss "CABLE_ROUTE*") 'ddfd-ov-add-route nil)
  (setq *ddfd-ov-cabs* (reverse *ddfd-ov-cabs*)
        *ddfd-ov-shafts* (reverse *ddfd-ov-shafts*)
        *ddfd-ov-routes* (reverse *ddfd-ov-routes*))
  (setq floors (ddfd-wiz-layer-floors))
  (foreach fl (append (mapcar 'car *ddfd-ov-rooms*) (mapcar 'cadr *ddfd-ov-cabs*)
                      (mapcar 'caddr *ddfd-ov-shafts*) (mapcar 'car *ddfd-ov-routes*))
    (if (and (/= fl "") (not (member fl floors))) (setq floors (cons fl floors))))
  (setq floors (ddfd-wiz-sort-floors floors))
  (if (or (ddfd-ov-floor-items *ddfd-ov-cabs* 1 "") (ddfd-ov-floor-items *ddfd-ov-shafts* 2 "")
          (ddfd-ov-floor-items *ddfd-ov-routes* 0 ""))
    (setq floors (append floors (list ""))))
  (setq *ddfd-ov-floors* floors)
  (foreach fl floors (ddfd-ov-floor-check fl))
  (ddfd-ov-check-dups)
  (ddfd-ov-check-rooms)
  (ddfd-ov-check-shafts)
  (ddfd-ov-check-paper)
  (setq *ddfd-ov-issues* (reverse *ddfd-ov-issues*))
  T)

;; 某步某级别的问题条数；step 为 nil 时统计全部
(defun ddfd-ov-count (step level / n r)
  (setq n 0)
  (foreach r *ddfd-ov-issues*
    (if (and (= (car r) level) (or (null step) (= (cadr r) step))) (setq n (1+ n))))
  n)

(defun ddfd-ov-seg-total (/ n r)
  (setq n 0)
  (foreach r *ddfd-ov-routes* (setq n (+ n (caddr r))))
  n)

(defun ddfd-ov-shaft-bases (/ s res)
  (foreach s *ddfd-ov-shafts*
    (if (not (member (car s) res)) (setq res (cons (car s) res))))
  (reverse res))

;; 步骤状态：ok 完成、warn 有提醒、err 有错误、todo 未开始、skip 不需要
(defun ddfd-ov-step-state (step count)
  (cond ((> (ddfd-ov-count step "err") 0) "err")
        ((> (ddfd-ov-count step "warn") 0) "warn")
        ((> count 0) "ok")
        (T "todo")))

;; ((步骤号 名称 状态 说明) ...)
(defun ddfd-ov-steps (/ real-floors exported errs)
  (setq real-floors (vl-remove "" *ddfd-ov-floors*)
        exported *ddfd-wiz-last-export*
        errs (ddfd-ov-count nil "err"))
  (list
    (list 1 "建楼层" (if real-floors "ok" "todo") (strcat (itoa (length real-floors)) " 层"))
    (list 2 "定义房间" (ddfd-ov-step-state 2 (length *ddfd-ov-rooms*)) (strcat (itoa (length *ddfd-ov-rooms*)) " 间"))
    (list 3 "标柜子" (ddfd-ov-step-state 3 (length *ddfd-ov-cabs*)) (strcat (itoa (length *ddfd-ov-cabs*)) " 台"))
    (list 4 "画通道" (ddfd-ov-step-state 4 (length *ddfd-ov-routes*))
          (strcat (itoa (length *ddfd-ov-routes*)) " 条 " (itoa (ddfd-ov-seg-total)) " 段"))
    (if (and (< (length real-floors) 2) (null *ddfd-ov-shafts*))
      (list 5 "标竖井" "skip" "单层不需要")
      (list 5 "标竖井" (ddfd-ov-step-state 5 (length *ddfd-ov-shafts*))
            (strcat (itoa (length (ddfd-ov-shaft-bases))) " 个")))
    (cond
      ((> errs 0) (list 6 "检查导出" "err" (strcat (itoa errs) " 个错误")))
      ((and exported (= (car exported) "fail")) (list 6 "检查导出" "err" "上次导出失败"))
      (exported (list 6 "检查导出" "ok" (strcat "已导出 " (caddr exported))))
      ((and *ddfd-ov-cabs* *ddfd-ov-routes*) (list 6 "检查导出" "todo" "可以导出"))
      (T (list 6 "检查导出" "todo" "还没有数据")))))

(defun ddfd-ov-state-mark (state)
  (cdr (assoc state '(("ok" . "[√]") ("warn" . "[!]") ("err" . "[×]") ("todo" . "[ ]") ("skip" . "[-]")))))

;; acad_strlsort 不带 lambda，柜子多时也快；出错或丢项时用原顺序
(defun ddfd-ov-sort-names (names / sorted)
  (if names
    (progn
      (setq sorted (vl-catch-all-apply 'acad_strlsort (list names)))
      (if (or (vl-catch-all-error-p sorted) (/= (length sorted) (length names))) names sorted))))

(defun ddfd-ov-floor-label (fl) (if (= fl "") "楼层未知" fl))

(defun ddfd-ov-print-floor (fl / rooms cabs routes shafts outside segs r names s bases)
  (setq rooms (ddfd-ov-floor-items *ddfd-ov-rooms* 0 fl)
        cabs (ddfd-ov-floor-items *ddfd-ov-cabs* 1 fl)
        routes (ddfd-ov-floor-items *ddfd-ov-routes* 0 fl)
        shafts (ddfd-ov-floor-items *ddfd-ov-shafts* 2 fl)
        segs 0)
  (foreach r routes (setq segs (+ segs (caddr r))))
  (foreach s shafts (if (not (member (car s) bases)) (setq bases (cons (car s) bases))))
  (princ (strcat "\n" (ddfd-ov-floor-label fl) "：房间 " (itoa (length rooms)) " 间，柜子 " (itoa (length cabs)) " 台，通道 "
                 (itoa (length routes)) " 条 " (itoa segs) " 段，竖井 "
                 (if bases (ddfd-join (reverse bases) "、") "无")))
  (foreach r rooms
    (setq names (ddfd-ov-sort-names (mapcar 'car (ddfd-ov-floor-items cabs 5 (caddr r)))))
    (princ (strcat "\n  " (cadr r) "（" (itoa (length names)) " 台）"
                   (if names (strcat "：" (ddfd-join names "、")) ""))))
  (setq outside (ddfd-ov-floor-items cabs 5 nil))
  (if outside
    (princ (strcat "\n  " (if rooms "不在任何房间" "柜子") "（" (itoa (length outside)) " 台）："
                   (ddfd-join (ddfd-ov-sort-names (mapcar 'car outside)) "、")))))

;; 竖井配对：每个竖井标到了哪些楼层
(defun ddfd-ov-print-shafts (/ b fl line hit real-floors)
  (setq real-floors (vl-remove "" *ddfd-ov-floors*))
  (if *ddfd-ov-shafts*
    (progn
      (princ "\n竖井配对：")
      (foreach b (ddfd-ov-shaft-bases)
        (setq line (strcat "\n  " b "："))
        (foreach fl real-floors
          (setq hit (vl-remove-if-not '(lambda (s) (and (= (car s) b) (= (caddr s) fl))) *ddfd-ov-shafts*))
          (setq line (strcat line fl (if hit "√ " "× "))))
        (princ line)))))

(defun ddfd-ov-print-issues (/ n r shown)
  (setq n (length *ddfd-ov-issues*) shown 0)
  (if (> n 0)
    (progn
      (princ (strcat "\n问题清单（错误 " (itoa (ddfd-ov-count nil "err"))
                     "，提醒 " (itoa (ddfd-ov-count nil "warn"))
                     "，说明 " (itoa (ddfd-ov-count nil "info")) "）："))
      (foreach level '("err" "warn" "info")
        (foreach r *ddfd-ov-issues*
          (if (and (= (car r) level) (< shown 40))
            (progn
              (setq shown (1+ shown))
              (princ (strcat "\n  " (cond ((= level "err") "[错误] ") ((= level "warn") "[提醒] ") (T "[说明] "))
                             (nth 4 r)
                             (if (/= (nth 3 r) "") (strcat "（句柄 " (nth 3 r) "）") "")))))))
      (if (> n shown) (princ (strcat "\n  还有 " (itoa (- n shown)) " 条没列出。"))))
    (princ "\n没有发现问题。")))

(defun ddfd-ov-print (/ s fl)
  (princ "\n=============== 定义总览 ===============")
  (foreach s (ddfd-ov-steps)
    (princ (strcat "\n  " (ddfd-ov-state-mark (caddr s)) " 第" (itoa (car s)) "步 " (cadr s) "：" (cadddr s))))
  (foreach fl *ddfd-ov-floors* (ddfd-ov-print-floor fl))
  (ddfd-ov-print-shafts)
  (ddfd-ov-print-issues)
  (princ))

;; —— 给面板的文件 ——
;; 中望的 open 支持 UTF-8 参数，AutoCAD 2018 不支持，退回系统编码；面板读取时自动识别
(defun ddfd-ov-open (path / f)
  (setq f (vl-catch-all-apply 'open (if *ddfd-ov-utf8* (list path "w" "utf8") (list path "w"))))
  (if (vl-catch-all-error-p f) nil f))

(defun ddfd-ov-temp-dir (/ d)
  (setq d (getenv "TEMP"))
  (if (or (null d) (= d "")) (setq d (getvar "TEMPPREFIX")))
  (vl-string-right-trim "\\" d))

;; 加载时试一次 open 的编码参数：*error* 里 vl-catch-all-apply 接不住参数错误，不能到写文件时才试
(defun ddfd-ov-probe-open (/ tmp f)
  (setq tmp (strcat (ddfd-ov-temp-dir) "\\ddfd-open-test.tmp")
        f (vl-catch-all-apply 'open (list tmp "w" "utf8")))
  (setq *ddfd-ov-utf8* (and f (not (vl-catch-all-error-p f))))
  (if *ddfd-ov-utf8*
    (progn (close f) (vl-file-delete tmp))))
(ddfd-ov-probe-open)

;; TAB 分隔的一项：把分隔符和换行换成空格
(defun ddfd-ov-clean (s / c)
  (foreach c '("\t" "\r" "\n")
    (setq s (ddfd-string-replace-all " " c (if s s ""))))
  s)

(defun ddfd-ov-num (v) (rtos v 2 3))

(defun ddfd-ov-write-row (fh cells / c first)
  (setq first T)
  (foreach c cells
    (if first (setq first nil) (princ "\t" fh))
    (princ (ddfd-ov-clean c) fh))
  (write-line "" fh))

;; 顶点直接逐个写进文件，不拼成长字符串；格式 x,y;x,y;...
(defun ddfd-ov-write-points (fh tag cells pts / c p)
  (princ tag fh)
  (foreach c cells
    (princ "\t" fh)
    (princ (ddfd-ov-clean c) fh))
  (princ "\t" fh)
  (foreach p pts
    (princ (strcat (ddfd-ov-num (car p)) "," (ddfd-ov-num (cadr p)) ";") fh))
  (write-line "" fh))

(defun ddfd-ov-now ()
  (cond ((menucmd "M=$(edtime,$(getvar,date),YYYY-MO-DD HH:MM:SS)")) (T "")))

(defun ddfd-ov-write-body (fh / r s)
  (ddfd-ov-write-row fh (list "DDFDOVERVIEW" "1"))
  (ddfd-ov-write-row fh (list "ID" (rtos (getvar "DATE") 2 8)))
  (ddfd-ov-write-row fh (list "TIME" (ddfd-ov-now)))
  (ddfd-ov-write-row fh (list "DWG" (strcat (getvar "DWGPREFIX") (getvar "DWGNAME"))))
  (ddfd-ov-write-row fh (list "VERSION" *ddfd-cable-version*))
  (ddfd-ov-write-row fh (list "CURFLOOR" (cond (*ddfd-wiz-floor*) (T ""))))
  (foreach s (ddfd-ov-steps)
    (ddfd-ov-write-row fh (list "STEP" (itoa (car s)) (cadr s) (caddr s) (cadddr s))))
  (foreach s *ddfd-ov-floors*
    (ddfd-ov-write-row fh (list "FLOOR" s)))
  (foreach r *ddfd-ov-rooms*
    (ddfd-ov-write-points fh "ROOM"
      (list (car r) (cadr r) (caddr r) (itoa (length (ddfd-ov-room-cabs (caddr r)))))
      (nth 3 r)))
  (foreach r *ddfd-ov-cabs*
    (ddfd-ov-write-row fh
      (list "CAB" (cadr r) (car r) (caddr r) (ddfd-ov-num (nth 3 r)) (ddfd-ov-num (nth 4 r))
            (cond ((nth 5 r)) (T "")) (nth 6 r))))
  (foreach r *ddfd-ov-shafts*
    (ddfd-ov-write-row fh
      (list "SHAFT" (caddr r) (car r) (cadr r) (cadddr r) (ddfd-ov-num (nth 4 r)) (ddfd-ov-num (nth 5 r)))))
  (foreach r *ddfd-ov-routes*
    (ddfd-ov-write-points fh "ROUTE" (list (car r) (cadr r) (itoa (caddr r))) (nth 3 r)))
  (foreach r *ddfd-ov-issues*
    (ddfd-ov-write-row fh (list "ISSUE" (car r) (itoa (cadr r)) (caddr r) (nth 3 r) (nth 4 r))))
  (if *ddfd-wiz-last-export*
    (ddfd-ov-write-row fh (cons "EXPORT" *ddfd-wiz-last-export*))))

;; %TEMP%\DDFD-Cable\overview.txt：先写 .tmp 再改名，面板不会读到半个文件。第一行 DDFDOVERVIEW 1，之后按行首分类：
;;   ID / TIME / DWG / VERSION / CURFLOOR（向导正在处理的楼层，面板跟着切换）
;;   STEP 步骤号 名称 状态 说明；FLOOR 楼层（空串是楼层未知）
;;   ROOM 楼层 名称 句柄 柜子数 顶点；CAB 楼层 柜名 句柄 x y 房间句柄 房间名
;;   SHAFT 楼层 配对名 全名 句柄 x y；ROUTE 楼层 句柄 段数 顶点
;;   ISSUE 级别 步骤号 类别 句柄 文字；EXPORT ok或fail 目录 时间
(defun ddfd-ov-write-file (/ dir tmp out fh result)
  (setq dir (strcat (ddfd-ov-temp-dir) "\\DDFD-Cable")
        tmp (strcat dir "\\overview.tmp")
        out (strcat dir "\\overview.txt"))
  (vl-mkdir dir)
  (if (setq fh (ddfd-ov-open tmp))
    (progn
      (setq result (vl-catch-all-apply 'ddfd-ov-write-body (list fh)))
      (close fh)
      (if (vl-catch-all-error-p result)
        (progn (vl-file-delete tmp) nil)
        (progn
          (if (findfile out) (vl-file-delete out))
          (vl-file-rename tmp out))))))

;; 问题写成 CAD 结果卡片的文件格式：装了面板的电脑上会自动弹出卡片，点条目定位到图上
(defun ddfd-ov-write-card (/ dir tmp out fh short r)
  (setq dir (strcat (ddfd-ov-temp-dir) "\\AA-CAD-Report")
        tmp (strcat dir "\\report.tmp")
        out (strcat dir "\\report.txt")
        short (strcat "电缆检查：错误 " (itoa (ddfd-ov-count nil "err"))
                      "，提醒 " (itoa (ddfd-ov-count nil "warn"))))
  (vl-mkdir dir)
  (if (setq fh (ddfd-ov-open tmp))
    (progn
      (ddfd-ov-write-row fh (list "AAREPORT" "1"))
      (ddfd-ov-write-row fh (list "ID" (strcat (rtos (getvar "DATE") 2 8) "-DDFD_CHECK")))
      (ddfd-ov-write-row fh (list "CMD" "电缆检查"))
      (ddfd-ov-write-row fh (list "TIME" (ddfd-ov-now)))
      (ddfd-ov-write-row fh (list "DWG" (strcat (getvar "DWGPREFIX") (getvar "DWGNAME"))))
      (ddfd-ov-write-row fh (list "SHORT" short))
      (ddfd-ov-write-row fh (list "SUM" short))
      (foreach r *ddfd-ov-issues*
        (ddfd-ov-write-row fh (list "ITEM" (car r) (caddr r) (nth 3 r) (nth 4 r))))
      (close fh)
      (if (findfile out) (vl-file-delete out))
      (vl-file-rename tmp out))))

;; 重新读图并写总览文件。只是给面板看的，出错只提示一句，不影响刚做完的步骤
(defun ddfd-ov-refresh (/ result)
  (setq result (vl-catch-all-apply 'ddfd-ov-collect nil))
  (if (vl-catch-all-error-p result)
    (progn (princ (strcat "\n读取定义总览时出错: " (vl-catch-all-error-message result))) nil)
    (progn
      (setq result (vl-catch-all-apply 'ddfd-ov-write-file nil))
      (if (vl-catch-all-error-p result)
        (princ (strcat "\n写定义总览文件时出错: " (vl-catch-all-error-message result))))
      T)))

;; 体检：刷新总览，弹结果卡片
(defun ddfd-ov-check ()
  (if (ddfd-ov-refresh)
    (progn
      (vl-catch-all-apply 'ddfd-ov-write-card nil)
      T)))

;; 按句柄缩放到对象并选中。文字、块放大到能看清周围，房间、通道看全整个对象
(defun ddfd:zoom (h / en ed pts box cx cy size w)
  (if (and h (setq en (handent h)) (setq ed (entget en)))
    (progn
      (setq pts (if (wcmatch (cdr (assoc 0 ed)) "*POLYLINE")
                  (ddfd-room-vertices en)
                  (list (cdr (assoc 10 ed))))
            box (ddfd-ov-bbox pts)
            cx (/ (+ (car box) (caddr box)) 2.0)
            cy (/ (+ (cadr box) (cadddr box)) 2.0)
            size (max (- (caddr box) (car box)) (- (cadddr box) (cadr box)) (cond ((cdr (assoc 40 ed))) (T 1.0)))
            w (* size (if (cdr pts) 1.2 8.0)))
      (command "_.ZOOM" "_W"
               (trans (list (- cx w) (- cy (* 0.6 w)) 0.0) 0 1)
               (trans (list (+ cx w) (+ cy (* 0.6 w)) 0.0) 0 1))
      (sssetfirst nil (ssadd en))
      (princ (strcat "\n已定位到对象 " h)))
    (princ (strcat "\n找不到对象 " (if h h "") "（可能已删除，或不在当前图纸）")))
  (princ))

;; 结果卡片点条目时发的是 aa:rep-zoom：没加载 AA 整合版本时用这里的定位
(if (not aa:rep-zoom)
  (defun aa:rep-zoom (h) (ddfd:zoom h)))

;; —— 第6步：检查并导出到实际桌面（网页版专用） ——
;; 依次尝试：Shell Folders（已解析路径，兼容桌面重定向、中文路径及 OneDrive 桌面）→
;; User Shell Folders（可能含 %USERPROFILE% 等变量，展开后再用）→ %USERPROFILE%\Desktop；返回第一个存在的目录
(defun ddfd-wiz-reg-folder (key / result)
  (setq result (vl-catch-all-apply 'vl-registry-read
                 (list (strcat "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\" key)
                       "Desktop")))
  (if (and (not (vl-catch-all-error-p result)) (= (type result) 'STR) (/= result ""))
    (ddfd-wiz-expand-env result)))

;; 展开路径里的 %变量%（只展开能取到值的，取不到的原样保留）
(defun ddfd-wiz-expand-env (s / p q nm val)
  (setq p 0)
  (while (and (setq p (vl-string-search "%" s p))
              (setq q (vl-string-search "%" s (1+ p))))
    (setq nm (substr s (+ p 2) (- q p 1)))
    (if (and (/= nm "") (setq val (getenv nm)))
      (setq s (strcat (substr s 1 p) val (substr s (+ q 2))) p (+ p (strlen val)))
      (setq p (1+ q))))
  s)

(defun ddfd-wiz-desktop-folder (/ dirs dir res)
  (setq dirs (list (ddfd-wiz-reg-folder "Shell Folders")
                   (ddfd-wiz-reg-folder "User Shell Folders")
                   (if (getenv "USERPROFILE") (strcat (getenv "USERPROFILE") "\\Desktop"))))
  (foreach dir dirs
    (if (and (not res) dir (vl-file-directory-p dir)) (setq res dir)))
  res)

;; 导出四个CSV到桌面，结果记进 *ddfd-wiz-last-export*，面板从总览文件里读。成功返回 T
(defun ddfd-wiz-export-run (/ desktop outdir ok)
  (setq desktop (ddfd-wiz-desktop-folder))
  (if desktop
    (progn
      (setq outdir desktop)
      (if (not (wcmatch outdir "*\\"))
        (setq outdir (strcat outdir "\\")))
      (princ (strcat "\n自动导出目录：" outdir))
      (setq ok (ddfd-do-export outdir))
      (setq *ddfd-wiz-last-export* (list (if ok "ok" "fail") outdir (ddfd-ov-now)))
      (if ok
        (progn
          (princ (strcat "\n已导出到桌面：" outdir))
          (princ "\n文件：柜子坐标.csv、路径线段.csv、竖井.csv、房间范围.csv。"))))
    (progn
      (setq *ddfd-wiz-last-export* (list "fail" "" (ddfd-ov-now)))
      (princ "\n无法读取或访问 Windows 桌面目录，未导出任何数据。可改用 DDFD_EXPORT_CABLE_ROUTE 手动指定导出目录。")))
  ok)

(defun ddfd-wiz-step6 (/ errs)
  (princ "\n———— 第6步：检查导出 ————")
  (if (ddfd-ov-check) (ddfd-ov-print))
  (setq errs (ddfd-ov-count nil "err"))
  (if (or (= errs 0)
          (ddfd-wiz-yesno (strcat "\n还有 " (itoa errs) " 个错误，导出的数据可能不完整。仍然导出吗?") "N"))
    (if (ddfd-wiz-export-run)
      (progn
        (princ "\n请回到网页版“电缆统计”，将这四个CSV拖入导入区域，点击“上传并保存”。")
        (if (ddfd-wiz-yesno "\n现在打开网页版工作台吗?" "N")
          (startapp "explorer.exe" *ddfd-web-url*))))
    (princ "\n已取消导出。改好后再运行第6步。"))
  (princ))

;; 保存并恢复用户环境（捕捉模式、当前图层）
(defun ddfd-wiz-restore ()
  (if *ddfd-wiz-oldos* (setvar "OSMODE" *ddfd-wiz-oldos*))
  (if (and *ddfd-wiz-oldlayer* (tblsearch "LAYER" *ddfd-wiz-oldlayer*))
    (setvar "CLAYER" *ddfd-wiz-oldlayer*)
  )
  (setq *ddfd-wiz-oldos* nil)
  (setq *ddfd-wiz-oldlayer* nil)
)

;; 按需连跑全部步骤，每步之间确认
(defun ddfd-wiz-all (/ go)
  (setq go T)
  (ddfd-wiz-step1 nil)
  (if go (if (ddfd-wiz-yesno "\n第1步完成。进入第2步(定义房间)?" "Y") (ddfd-wiz-step2 nil) (setq go nil)))
  (if go (if (ddfd-wiz-yesno "\n第2步完成。进入第3步(标柜子)?" "Y") (ddfd-wiz-step3 nil) (setq go nil)))
  (if go (if (ddfd-wiz-yesno "\n第3步完成。进入第4步(画通道)?" "Y") (ddfd-wiz-step4 nil) (setq go nil)))
  (if go (if (ddfd-wiz-yesno "\n第4步完成。进入第5步(标竖井)?" "Y") (ddfd-wiz-step5) (setq go nil)))
  (if go (if (ddfd-wiz-yesno "\n第5步完成。进入第6步(检查导出)?" "Y") (ddfd-wiz-step6) (setq go nil)))
  (if (not go)
    (princ "\n已停在当前步骤。之后输入 DDFD_CABLE_WIZARD 可从任意步骤继续。")
  )
)

;; stepno：0 全部，1~6 对应六步，7 只导出（面板用）。arg：第1步是楼层文字，第2~4步是楼层，nil 表示在命令行问。
;; 每步结束都刷新总览文件，面板随之更新
(defun ddfd-wiz-run (stepno arg / *error*)
  (setq *ddfd-wiz-oldos* (getvar "OSMODE"))
  (setq *ddfd-wiz-oldlayer* (getvar "CLAYER"))
  (defun *error* (msg)
    (ddfd-wiz-restore)
    (princ (strcat "\n已中断: " msg))
    (princ "\n可重新输入 DDFD_CABLE_WIZARD 从任意步骤继续。")
    (ddfd-ov-refresh)
    (princ)
  )
  (cond
    ((= stepno 0) (ddfd-wiz-all))
    ((= stepno 1) (ddfd-wiz-step1 arg))
    ((= stepno 2) (ddfd-wiz-step2 arg))
    ((= stepno 3) (ddfd-wiz-step3 arg))
    ((= stepno 4) (ddfd-wiz-step4 arg))
    ((= stepno 5) (ddfd-wiz-step5))
    ((= stepno 6) (ddfd-wiz-step6))
    ((= stepno 7) (ddfd-wiz-export-run))
  )
  (ddfd-wiz-restore)
  (ddfd-ov-refresh)
  (princ)
)

;; 菜单每行带上这一步的当前状态，一眼能看出做到哪了
(defun ddfd-wiz-menu-line (key step desc / s)
  (setq s (assoc step (ddfd-ov-steps)))
  (princ (strcat "\n  [" key "] " (ddfd-ov-state-mark (caddr s)) " " (cadr s) "  " (cadddr s) " - " desc)))

(defun ddfd-wiz-menu (ok)
  (princ "\n=============== 电缆长度统计 · 引导向导 ===============")
  (if ok
    (progn
      (ddfd-wiz-menu-line "1" 1 "写出图纸的楼层，自动建 4 类图层")
      (ddfd-wiz-menu-line "2" 2 "选闭合多段线，输入房间名称（再选一次可改名）")
      (ddfd-wiz-menu-line "3" 3 "在柜后出线点点一下，输入柜名")
      (ddfd-wiz-menu-line "4" 4 "沿电缆沟/桥架中心线画多段线")
      (ddfd-wiz-menu-line "5" 5 "跨楼层电缆用，自动写 ZJn_楼层 配对文字")
      (ddfd-wiz-menu-line "6" 6 "体检后把四个CSV导出到桌面"))
    (princ "\n  （读取当前状态失败，步骤仍可使用）\n  [1] 建楼层  [2] 定义房间  [3] 标柜子  [4] 画通道  [5] 标竖井  [6] 检查导出"))
  (princ "\n  [A] 从头一步步来（新图推荐）")
  (princ "\n  [L] 查看定义总览：每层的房间、柜子、通道、竖井")
  (princ "\n  [Q] 退出向导")
  (princ)
)

(defun ddfd-wiz-list ()
  (if (ddfd-ov-check) (ddfd-ov-print))
  (princ))

(defun c:DDFD_CABLE_WIZARD (/ choice first done)
  (setq first T)
  (setq done nil)
  (while (not done)
    (ddfd-wiz-menu (ddfd-ov-refresh))
    (initget "1 2 3 4 5 6 A L Q")
    (setq choice (getkword (strcat "\n选择要做的步骤 [1/2/3/4/5/6/A/L/Q] <" (if first "A" "Q") ">: ")))
    (if (not choice) (setq choice (if first "A" "Q")))
    (setq first nil)
    (cond
      ((= choice "Q") (setq done T))
      ((= choice "A") (ddfd-wiz-run 0 nil) (setq done T))
      ((= choice "L") (ddfd-wiz-list))
      (T (ddfd-wiz-run (atoi choice) nil))
    )
  )
  (princ "\n向导已退出，单步做完会回到菜单；随时输入 DCW 或 DDFD_CABLE_WIZARD 再进。")
  (princ)
)

(defun c:DCW () (c:DDFD_CABLE_WIZARD))
(defun c:DCV () (ddfd-wiz-list))
(defun c:DDFD_CABLE_LIST () (ddfd-wiz-list))
(defun c:DDFD_CABLE_LAYERS () (ddfd-wiz-run 1 nil))
(defun c:DDFD_CABLE_ROOMS () (ddfd-wiz-run 2 nil))
(defun c:DDFD_CABLE_CABINETS () (ddfd-wiz-run 3 nil))
(defun c:DDFD_CABLE_ROUTES () (ddfd-wiz-run 4 nil))
(defun c:DDFD_CABLE_SHAFTS () (ddfd-wiz-run 5 nil))
(defun c:DDFD_CABLE_EXPORT_RUN () (ddfd-wiz-run 6 nil))

;; —— 面板调用入口：SendCommand 发 (ddfd:cabinets "2F") 这样的表达式，发之前面板要确认 CMDACTIVE 为 0 ——
(defun ddfd:floors (spec) (ddfd-wiz-run 1 spec))
(defun ddfd:rooms (floor) (ddfd-wiz-run 2 floor))
(defun ddfd:cabinets (floor) (ddfd-wiz-run 3 floor))
(defun ddfd:routes (floor) (ddfd-wiz-run 4 floor))
(defun ddfd:shafts () (ddfd-wiz-run 5 nil))
(defun ddfd:export () (ddfd-wiz-run 7 nil))
(defun ddfd:refresh () (ddfd-ov-refresh) (princ))
(defun ddfd:check () (ddfd-ov-check) (princ))

(princ (strcat "\n已加载电缆统计引导向导（版本 " *ddfd-cable-version* "）。输入 DCW 打开向导，DCV 查看定义总览。"))
(princ "\n六步: 1建楼层 → 2定义房间 → 3标柜子 → 4画通道 → 5标竖井 → 6检查导出")
(princ)
