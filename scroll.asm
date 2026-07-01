; =====================================================================
;  R-TYPE-STYLE SHMUP  -  STAGE 2: SCROLL + PLAYER SHIP (IJKL) + BULLET (SPACE)
;  Target: Commodore 64 (PAL)   Assembler: ACME
;  Build:  acme -f cbm -o scroll.prg scroll.asm
;  Run:    x64sc scroll.prg    (auto-runs via BASIC stub, or SYS 2064)
; =====================================================================

VIC      = $d000
RASTER   = $d012
SCROLY   = $d011
SCROLX   = $d016
VICMEM   = $d018
VICIRQ   = $d019
IRQMASK  = $d01a
BORDER   = $d020
BGCOL0   = $d021
BGCOL1   = $d022
BGCOL2   = $d023

CIA1_ICR = $dc0d
CIA2_ICR = $dd0d

IRQVEC   = $0314

MUX_LEAD = 16               ; raster lead before sprite Y: must be big enough to
                            ; program a full band (~7) of same-line sprites before
                            ; the raster reaches them. Each costs ~100+ cycles (a
                            ; couple of scanlines), so a band needs a dozen-plus
                            ; lines of lead. Measured: 3 of 7 same-line sprites
                            ; appeared at LEAD=3, all 7 at 16; the late ones were
                            ; missing their turn-on line, not short of hw slots.
SPRSPAN  = 37               ; min Y gap to safely reuse a hw sprite (21 tall + MUX_LEAD)

ENEMY_SPEED   = 2
SPAWN_INTERVAL = 45
EXPLODE_FRAMES = 8
ENEMY_COLOR   = 2          ; red
EXPLODE_COLOR = 1          ; white
HITW          = 12         ; hit box half-width (pixels)
HITH          = 12         ; hit box half-height (pixels)
ENEMY_FIRE_INTERVAL = 30
EBULLET_SPEED = 3
EBULLET_COLOR = 3          ; cyan

D016_HUD      = $18        ; MCM=1, 40-col, fine=0  (HUD rows)
D016_PLAY_BASE = $10       ; MCM=1, 38-col          (| fine_x for playfield)
SPLIT_LINE    = 65         ; raster line of the row1/row2 split (tunable)
HUD_COLOR     = 1          ; HUD band color (white)
DIGIT_BASE    = 16         ; screen codes for digit 0..9 (16-25)
SCORE_PER_KILL = $10       ; 10 points per kill (BCD)

BOSS_KILL_THRESHOLD = 5
BOSS_HP       = 5
BOSS_COLOR    = 4          ; purple
BOSS_ENTER_SPEED = 2
BOSS_FIRE_INTERVAL = 50
BOSS_DEATH_FRAMES = 30
BOSS_FLASH_FRAMES = 4
BS_INACTIVE = 0
BS_ENTER    = 1
BS_FIGHT    = 2
BS_DYING    = 3

PLAYER_LIVES    = 3
PEXPLODE_FRAMES = 24
INVULN_FRAMES   = 100
PHITW           = 14
PHITH           = 16
PS_ALIVE        = 0
PS_EXPLODE      = 1
PS_INVULN       = 2

; --- charge beam ---
CHARGE_THRESHOLD  = 40         ; frames held before release fires the beam
CHARGE_MAX        = 90         ; cap for chargeTimer
BEAM_COLOR        = 1          ; white (distinct from yellow-7 normal shots)
SHIP_COLOR_NORMAL = 1          ; white hull (matches SP0COL init)
SHIP_COLOR_CHARGE = 3          ; cyan  (pulses with SHIP_COLOR_NORMAL while charging)
SHIP_COLOR_READY  = 7          ; yellow (steady, charge >= threshold)

; ---- two screen buffers (both inside VIC bank 0) -----------------------
BUF_A    = $0400
BUF_B    = $3800            ; moved from $0c00: program code+tables grew past $0c00 and
                            ; clobbered the row-address tables that lived inside the old BUF_B
COLORRAM = $d800
CHARSET  = $2000

; $D018 values: screen ptr in top nibble (units of $0400), charset $2000
D18_A    = %00011000        ; screen $0400, charset $2000
D18_B    = %11101000        ; screen $3800 (VM=14), charset $2000 (CB=4)

; ---- zero page ---------------------------------------------------------
zp_dst   = $f9              ; 16-bit dst pointer
zp_map   = $fb              ; map pointer (next right-edge column, 25 bytes)
zp_fsrc  = $f7              ; front-buffer row src (for building back buffer)
zp_bdst  = $f5              ; back-buffer row dst

fine_x   = $02              ; fine scroll 7..0
build_row= $03              ; next screen row to build this char-step (0..24)
front_is_a = $04            ; 1 = buffer A is front, 0 = buffer B is front
frame_ready = $06           ; nonzero = a frame elapsed; cleared by main loop

ROWS_PER_FRAME = 4          ; build 4 rows/frame -> 25 rows done in ~7 frames

; =====================================================================
;  BASIC stub: 10 SYS 2064
; =====================================================================
* = $0801
        !byte $0c,$08,$0a,$00,$9e,$32,$30,$36,$34,$00,$00,$00

* = $0810
start
        sei
        lda #$7f
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR
        lda CIA2_ICR

        jsr build_charset
        lda #0
        sta score
        sta score+1
        sta score+2
        lda #0
        sta bossState
        sta killCount
        jsr set_colors
        jsr sid_init

        ; --- initial state: A is front, fill A from first 40 map columns,
        ;     and copy A->B so both buffers start identical -------------
        lda #1
        sta front_is_a

        jsr fill_front_from_map     ; fills BUF_A and positions zp_map @ col40
        jsr copy_a_to_b             ; B starts identical to A
        jsr init_hud_bar            ; fill rows 0-1 of both buffers with HUD bar
        jsr init_sprites            ; sprite pointers (both buffers), regs, art
        lda #30
        sta spawnTimer          ; first enemy spawns soon
        lda #0
        sta spawnIndex
        lda #ENEMY_FIRE_INTERVAL
        sta enemyFireTimer
        lda #6
        sta enemyFireIndex

        lda #7
        sta fine_x
        lda #2
        sta build_row

        ; --- VIC setup: multicolor, 38-col, show buffer A ---------------
        lda #D18_A
        sta VICMEM

        lda #%00011000              ; MCM=1, 38col=0(set later), xscroll=0
        ora #7                      ; fine = 7
        sta SCROLX
        ; switch to 38-column to hide seam (clear bit3)
        lda SCROLX
        and #%11110111
        sta SCROLX

        lda #%00011011
        sta SCROLY
        and #$7f
        sta SCROLY

        lda #0
        sta BORDER
        sta BGCOL0

        ; --- raster IRQ at line 250 ------------------------------------
        lda #<scroll_irq
        sta IRQVEC
        lda #>scroll_irq
        sta IRQVEC+1
        lda #250
        sta RASTER
        lda #%00000001
        sta IRQMASK
        lda VICIRQ
        sta VICIRQ
        cli

main_loop
        lda frame_ready
        beq main_loop               ; wait for next frame
        lda #0
        sta frame_ready             ; consume it
        jsr player_update
        jsr spawn_enemies
        jsr enemy_fire
        jsr boss_update
        jsr update_enemies
        jsr update_enemy_bullets
        jsr update_bullets
        jsr check_hits
        jsr check_player_hit
        jsr sound_update
        jsr draw_hud
        jsr sort_sprites
        jsr build_schedule
        jmp main_loop

; =====================================================================
;  RASTER IRQ CHAIN
;  scroll_irq: bottom-of-frame work (scroll + frame flag) + arm mux chain
;  mux_irq:    programs hw sprites 1-7 round-robin, chains on raster
; =====================================================================

; --- bottom-of-frame IRQ: scroll work, set HUD $D016, arm split_irq ---
scroll_irq
        lda VICIRQ
        sta VICIRQ
        jsr scroll_step
        inc frame_ready
        ; HUD region (top of next frame): 40-col, no fine scroll
        lda #D016_HUD
        sta SCROLX
        ; arm the split IRQ at the HUD/playfield boundary
        lda #<split_irq
        sta IRQVEC
        lda #>split_irq
        sta IRQVEC+1
        lda #SPLIT_LINE
        sta RASTER
        pla
        tay
        pla
        tax
        pla
        rti

; --- split IRQ: switch to playfield scroll mode, then arm the mux chain ---
split_irq
        lda VICIRQ
        sta VICIRQ
        ; playfield region below the split: 38-col + fine scroll
        lda #D016_PLAY_BASE
        ora fine_x
        sta SCROLX
        ; arm next: mux chain (if sprites) else scroll_irq@250
        jsr park_mux_sprites
        lda #1
        sta muxHW
        ldx #0
        lda schFront
        beq sp_base0
        ldx #15
sp_base0
        stx muxIdx
        ldy schFront
        txa
        clc
        adc schCount,y
        sta muxEnd
        lda muxEnd
        cmp muxIdx
        beq sp_nosprites
        lda #<mux_irq
        sta IRQVEC
        lda #>mux_irq
        sta IRQVEC+1
        ldx muxIdx
        lda schY,x
        sec
        sbc #MUX_LEAD
        cmp #SPLIT_LINE+1       ; with a big MUX_LEAD, schY-LEAD can land at/above
        bcs sp_armok            ; the split. Clamp so we never schedule a passed
        lda #SPLIT_LINE+1       ; raster (would hang the chain a whole frame); the
sp_armok                       ; mux burst then programs from here via its behind-check.
        sta RASTER
        jmp sp_exit
sp_nosprites
        lda #<scroll_irq
        sta IRQVEC
        lda #>scroll_irq
        sta IRQVEC+1
        lda #250
        sta RASTER
sp_exit
        pla
        tay
        pla
        tax
        pla
        rti

; --- multiplex IRQ: program next hw sprite(s), chain to next raster line ---
mux_irq
        lda VICIRQ
        sta VICIRQ
mux_loop
        ldx muxIdx
        cpx muxEnd
        bcs mux_done
        ; program hw sprite muxHW from schedule entry x
        lda muxHW
        asl
        tay                     ; y = 2*hw (X/Y register index)
        lda schXlo,x
        sta $d000,y
        lda schY,x
        sta $d001,y
        ldy muxHW
        lda schXhi,x
        beq mx_clr
        lda $d010
        ora msbset,y            ; RMW: set bit for this hw sprite
        sta $d010
        jmp mx_col
mx_clr
        lda $d010
        and msbclr,y            ; RMW: clear bit for this hw sprite
        sta $d010
mx_col
        ldy muxHW
        lda schColor,x
        sta $d027,y
        ; per-sprite X-expand: set bit for this hw sprite if beam, else clear
        ; (Y still = muxHW from color write above)
        lda schExpand,x
        beq mx_noexp
        lda $d01d
        ora msbset,y
        sta $d01d
        jmp mx_expdone
mx_noexp
        lda $d01d
        and msbclr,y
        sta $d01d
mx_expdone
        ; advance schedule index + round-robin hw 1..7
        inc muxIdx
        ldy muxHW
        iny
        cpy #8
        bne mx_hwok
        ldy #1
mx_hwok
        sty muxHW
        ; decide next IRQ line or loop
        ldx muxIdx
        cpx muxEnd
        bcs mux_done
        lda schY,x
        sec
        sbc #MUX_LEAD
        cmp RASTER              ; desired vs current raster
        bcc mux_ltramp          ; desired < current -> behind -> program now
        sta RASTER              ; arm next IRQ
        cmp RASTER              ; re-read current raster (race check)
        bcc mux_ltramp          ; still behind -> loop
        jmp mux_exit
mux_done
        ; last sprite done -> hand off to scroll_irq at line 250
        lda #<scroll_irq
        sta IRQVEC
        lda #>scroll_irq
        sta IRQVEC+1
        lda #250
        sta RASTER
mux_exit
        pla
        tay
        pla
        tax
        pla
        rti
mux_ltramp                      ; trampoline: mux_loop out of short-branch range after expand insert
        jmp mux_loop

; --- init_hud_bar: fill rows 0-1 of BOTH buffers with char 2 + HUD color ---
; (temporary HUD marker; Task 2 replaces with score/lives digits)
init_hud_bar
        ldx #0
ihb_loop
        cpx #80                 ; 2 rows x 40 cols
        bcs ihb_done
        lda #0                  ; blank tile
        sta BUF_A,x
        sta BUF_B,x
        lda #HUD_COLOR
        sta COLORRAM,x
        inx
        jmp ihb_loop
ihb_done
        ; --- static labels: "Score: " row 0 col 0, "Ships left: " row 1 col 0 ---
        ldx #0
ihb_sc
        cpx #7
        bcs ihb_sc_done
        lda label_score,x
        sta BUF_A,x
        sta BUF_B,x
        inx
        jmp ihb_sc
ihb_sc_done
        ldx #0
ihb_sh
        cpx #12
        bcs ihb_sh_done
        lda label_ships,x
        sta BUF_A+40,x          ; row 1
        sta BUF_B+40,x
        inx
        jmp ihb_sh
ihb_sh_done
        rts

; ---------------------------------------------------------------------
; draw_hud: write 6 score digits (cols 0..5) + lives digit (col 38) to
; row 0 of both screen buffers. BCD score; score+2 = leftmost pair.
; ---------------------------------------------------------------------
draw_hud
        ; "Score: " is at row0 cols 0-6; score digits go at cols 7-12.
        ; high pair (score+2) -> cols 7,8
        lda score+2
        jsr dh_split            ; A hi-nibble -> dhHi (code), lo-nibble -> dhLo (code)
        lda dhHi
        sta BUF_A+7
        sta BUF_B+7
        lda dhLo
        sta BUF_A+8
        sta BUF_B+8
        ; mid pair (score+1) -> cols 9,10
        lda score+1
        jsr dh_split
        lda dhHi
        sta BUF_A+9
        sta BUF_B+9
        lda dhLo
        sta BUF_A+10
        sta BUF_B+10
        ; low pair (score+0) -> cols 11,12
        lda score+0
        jsr dh_split
        lda dhHi
        sta BUF_A+11
        sta BUF_B+11
        lda dhLo
        sta BUF_A+12
        sta BUF_B+12
        ; "Ships left: " is at row1 cols 0-11; lives digit at row1 col 12 (offset 52)
        lda lives
        clc
        adc #DIGIT_BASE
        sta BUF_A+52
        sta BUF_B+52
        rts

; split BCD byte A into two digit char codes: dhHi (high nibble), dhLo (low nibble)
dh_split
        pha
        lsr
        lsr
        lsr
        lsr
        clc
        adc #DIGIT_BASE
        sta dhHi
        pla
        and #$0f
        clc
        adc #DIGIT_BASE
        sta dhLo
        rts
dhHi !byte 0
dhLo !byte 0

; =====================================================================
;  PLAYER UPDATE  (once per frame from main loop)
;  TEMPORARY heartbeat: tints the border each frame to prove the frame
;  flag + main loop are alive. Replaced by real input/movement in Task 4.
; =====================================================================

; ---------------------------------------------------------------------
; player_update: state dispatcher. ALIVE -> normal play; EXPLODE ->
; frozen+blink+countdown then respawn/game-over; INVULN -> play+blink.
; ---------------------------------------------------------------------
player_update
        ; border flash countdown (game over feedback)
        lda flashTimer
        beq pu_disp
        dec flashTimer
        bne pu_disp
        lda #0
        sta BORDER
pu_disp
        lda playerState
        bne pu_not_alive
        jmp pu_normal_play      ; ALIVE: normal play (ends in rts)
pu_not_alive
        cmp #PS_INVULN
        beq pu_invuln
        ; PS_EXPLODE: frozen, blink, count down
        lda #$ff
        sta keyrow7             ; freeze firing during explosion (update_bullets reads keyrow7)
        jsr pu_blink
        dec playerTimer
        beq pu_explode_end
        rts
pu_explode_end
        lda lives
        beq pu_gameover
        jsr player_respawn
        rts
pu_gameover
        jsr game_over
        rts
pu_invuln
        jsr pu_normal_play      ; can move/fire while invulnerable
        jsr pu_blink
        dec playerTimer
        bne pu_inv_ret
        lda #PS_ALIVE
        sta playerState
        lda SPENA               ; ensure sprite on
        ora #%00000001
        sta SPENA
pu_inv_ret
        rts

pu_normal_play
        ; --- scan keyboard matrix rows ---
        lda #$ef
        sta $dc00                ; select row PA4 (I,J,K)
        lda $dc01
        sta keyrow4
        lda #$df
        sta $dc00                ; select row PA5 (L)
        lda $dc01
        sta keyrow5
        lda #$7f
        sta $dc00                ; select row PA7 (space)
        lda $dc01
        sta keyrow7

        ; --- vertical: I (bit1)=up, K (bit5)=down ---
        lda keyrow4
        and #%00000010
        bne pu_not_up
        lda player_y
        sec
        sbc #2
        sta player_y
pu_not_up
        lda keyrow4
        and #%00100000
        bne pu_not_down
        lda player_y
        clc
        adc #2
        sta player_y
pu_not_down

        ; --- horizontal: J (row4 bit2)=left, L (row5 bit2)=right ---
        lda keyrow4
        and #%00000100
        bne pu_not_left
        lda player_x
        sec
        sbc #2
        sta player_x
        lda player_x_hi
        sbc #0
        sta player_x_hi
pu_not_left
        lda keyrow5
        and #%00000100
        bne pu_not_right
        lda player_x
        clc
        adc #2
        sta player_x
        lda player_x_hi
        adc #0
        sta player_x_hi
pu_not_right

        jsr clamp_player
        jsr write_player_sprite
        rts

; blink sprite 0 by toggling SPENA bit 0 on (playerTimer & 4)
pu_blink
        lda playerTimer
        and #%00000100
        beq pb_show
        lda SPENA
        and #%11111110
        sta SPENA
        rts
pb_show
        lda SPENA
        ora #%00000001
        sta SPENA
        rts

; respawn player at start, become invulnerable
player_respawn
        lda #60
        sta player_x
        lda #0
        sta player_x_hi
        lda #120
        sta player_y
        lda #PS_INVULN
        sta playerState
        lda #INVULN_FRAMES
        sta playerTimer
        lda SPENA
        ora #%00000001
        sta SPENA
        jsr write_player_sprite
        rts

; player_hit: only acts when ALIVE. lose a life, start explosion.
player_hit
        lda playerState
        bne ph_ret
        dec lives
        lda #PS_EXPLODE
        sta playerState
        lda #PEXPLODE_FRAMES
        sta playerTimer
        jsr sfx_hit
ph_ret
        rts

; cph_overlap: bounding box between the PLAYER and virtual slot X.
; C set = overlap. Uses chDlo/chDhi scratch.
cph_overlap
        lda vsXlo,x             ; 16-bit dX = slotX - player_x
        sec
        sbc player_x
        sta chDlo
        lda vsXhi,x
        sbc player_x_hi
        sta chDhi
        bpl co_xpos
        lda #0
        sec
        sbc chDlo
        sta chDlo
        lda #0
        sbc chDhi
        sta chDhi
co_xpos
        lda chDhi
        bne co_no
        lda chDlo
        cmp #PHITW
        bcs co_no
        lda vsY,x               ; 8-bit |dY|
        sec
        sbc player_y
        bpl co_ypos
        eor #$ff
        clc
        adc #1
co_ypos
        cmp #PHITH
        bcs co_no
        sec                     ; overlap
        rts
co_no
        clc
        rts

; ---------------------------------------------------------------------
; check_player_hit: only when ALIVE. Test player vs enemy bullets
; (11..14) and enemy bodies (6..10). On hit -> despawn/explode source,
; call player_hit, return (one hit/frame).
; ---------------------------------------------------------------------
check_player_hit
        lda playerState
        bne cph_ret             ; only when ALIVE (0)
        ldx #11                 ; (a) enemy bullets
cph_eb
        cpx #15
        bcs cph_enemies
        lda vsActive,x
        beq cph_eb_next
        jsr cph_overlap
        bcc cph_eb_next
        jsr ue_despawn          ; enemy bullet gone
        jsr player_hit
        rts
cph_eb_next
        inx
        jmp cph_eb
cph_enemies
        ldx #6                  ; (b) enemy bodies
cph_en
        cpx #11
        bcs cph_ret
        lda vsActive,x
        beq cph_en_next
        lda vsState,x
        bne cph_en_next         ; already exploding
        jsr cph_overlap
        bcc cph_en_next
        lda bossState
        beq cph_en_kamikaze     ; no boss -> explode enemy
        ; boss piece is solid: damage the player, leave the piece
        jsr player_hit
        rts
cph_en_kamikaze
        ; kamikaze: explode enemy + hit player
        lda #1
        sta vsState,x
        lda #EXPLODE_FRAMES
        sta vsExplodeTimer,x
        lda #1                  ; white
        sta vsColor,x
        jsr player_hit
        rts
cph_en_next
        inx
        jmp cph_en
cph_ret
        rts

; ---------------------------------------------------------------------
; game_over: clear all actors, reset lives + timers, respawn player,
; flash border red.
; ---------------------------------------------------------------------
game_over
        ldx #0
go_clear
        cpx #15
        bcs go_done
        lda #0
        sta vsActive,x
        lda #255
        sta vsY,x
        inx
        jmp go_clear
go_done
        lda #PLAYER_LIVES
        sta lives
        lda #0
        sta score
        sta score+1
        sta score+2
        lda #0
        sta bossState
        sta killCount
        lda #30
        sta spawnTimer
        lda #ENEMY_FIRE_INTERVAL
        sta enemyFireTimer
        lda #PS_ALIVE
        sta playerState
        lda #60
        sta player_x
        lda #0
        sta player_x_hi
        lda #120
        sta player_y
        lda SPENA
        ora #%00000001
        sta SPENA
        jsr write_player_sprite
        lda #2                  ; red border flash
        sta BORDER
        lda #20
        sta flashTimer
        rts

; --- clamp player_x to [24,320], player_y to [70,229] ---
clamp_player
        ; Y low bound 70
        lda player_y
        cmp #70
        bcs cy_hi
        lda #70
        sta player_y
        jmp cx
cy_hi
        cmp #230                 ; >=230 -> clamp to 229
        bcc cx
        lda #229
        sta player_y
cx
        ; X low bound 24 (only possible when hi==0)
        lda player_x_hi
        bne cx_high
        lda player_x
        cmp #24
        bcs cx_done
        lda #24
        sta player_x
        jmp cx_done
cx_high
        ; hi>=1: clamp to max 320 ($140)
        lda player_x_hi
        cmp #2
        bcs cx_max               ; hi>=2 -> over max
        lda player_x             ; hi==1
        cmp #$41                 ; lo>$40 -> over max (320=$140)
        bcc cx_done
cx_max
        lda #$40
        sta player_x
        lda #1
        sta player_x_hi
cx_done
        rts

; --- write player_x/player_y to sprite 0 registers ---
write_player_sprite
        lda player_x
        sta $d000
        lda player_y
        sta $d001
        sei
        lda $d010
        and #%11111110           ; clear sprite 0 MSB
        ldx player_x_hi
        beq wps_done
        ora #%00000001
wps_done
        sta $d010
        cli
        rts

; park hardware sprites 1-7 below the screen (Y=$f8) so unused ones don't show stale data
park_mux_sprites
        lda #$f8
        sta $d003
        sta $d005
        sta $d007
        sta $d009
        sta $d00b
        sta $d00d
        sta $d00f
        rts

; =====================================================================
;  SORT_SPRITES: insertion-sort sortIdx[0..14] ascending by vsY[sortIdx[i]]
;  Outer index kept in ss_x (memory) to avoid X clobbering across inner loop.
; =====================================================================
sort_sprites
        ; --- flicker fairness: rotate sortIdx left by 1 each frame before
        ;     sorting. The insertion sort below is STABLE (stops on ==), so
        ;     this only permutes the order of EQUAL-Y entries -> on a band that
        ;     overflows the 7 mux-able hw slots, a different entry is the one
        ;     build_schedule drops each frame. Net: same-scanline overflow
        ;     blinks fairly instead of dropping the same sprite every frame. ---
        lda sortIdx             ; save sortIdx[0]
        sta tmpSlot
        ldx #0
fk_rot
        lda sortIdx+1,x         ; sortIdx[i] = sortIdx[i+1]
        sta sortIdx,x
        inx
        cpx #14
        bne fk_rot
        lda tmpSlot
        sta sortIdx+14          ; old [0] -> [14]
        lda #1
        sta ss_x
ss_outer
        lda ss_x
        cmp #15
        bcs ss_done
        ldx ss_x
        lda sortIdx,x
        sta tmpSlot             ; key slot
        tay
        lda vsY,y
        sta sortKey             ; key value
        lda ss_x
        sta sortJ               ; j = outer index
ss_inner
        lda sortJ
        beq ss_place            ; j==0 -> place
        tax
        dex                     ; j-1
        lda sortIdx,x           ; slot at j-1
        tay
        lda vsY,y               ; vsY[sortIdx[j-1]]
        cmp sortKey
        bcc ss_place            ; vsY[j-1] < key -> place here
        beq ss_place
        ; sortIdx[j] = sortIdx[j-1]
        lda sortIdx,x           ; value at j-1
        ldy sortJ
        sta sortIdx,y
        dec sortJ
        jmp ss_inner
ss_place
        ldx sortJ
        lda tmpSlot
        sta sortIdx,x
        inc ss_x
        jmp ss_outer
ss_done
        rts

; =====================================================================
;  BUILD_SCHEDULE: emit active sprites from sortIdx (Y order) into the
;  BACK schedule buffer, set schCount, swap schFront.
; =====================================================================
build_schedule
        lda schFront
        eor #1
        sta schBack
        ; write index -> schBackBase (base = 0 or 15)
        ldx #0
        lda schBack
        beq bs_base0
        ldx #15
bs_base0
        stx schBackBase
        stx bsBase
        ldy #0                  ; sortIdx position 0..14
bs_loop
        cpy #15
        bcs bs_end
        lda sortIdx,y
        sta tmpSlot             ; slot
        sty sortJ               ; save sortIdx position
        ldx tmpSlot
        lda vsActive,x
        beq bs_skip
        ; --- capacity guard: the round-robin mux reuses each hw sprite 7
        ;     emit-slots later. Don't emit if the sprite emitted 7 ago is
        ;     still on screen (Y gap < SPRSPAN); that would overwrite a
        ;     visible sprite. Cleanly DROP the overflow instead. Once >7
        ;     active fall in one SPRSPAN-line band, the surplus is skipped; the
        ;     per-frame sortIdx rotation cycles which one, so it blinks. ---
        lda schBackBase
        sec
        sbc bsBase              ; emitted so far this frame
        cmp #7
        bcc bs_emit             ; <7 emitted -> a hw slot is free
        lda schBackBase
        sec
        sbc #7
        tay                     ; Y = index of entry emitted 7 ago
        lda vsY,x               ; thisY (>= schY[7ago], Y-ascending)
        sec
        sbc schY,y
        cmp #SPRSPAN
        bcc bs_skip             ; gap too small -> hw still busy -> DROP
bs_emit
        ; src slot = X (tmpSlot); dst = schBackBase
        ldy schBackBase
        lda vsY,x
        sta schY,y
        lda vsXlo,x
        sta schXlo,y
        lda vsXhi,x
        sta schXhi,y
        lda vsColor,x
        sta schColor,y
        lda vsExpand,x
        sta schExpand,y
        inc schBackBase
bs_skip
        ldy sortJ
        iny
        jmp bs_loop
bs_end
        ; count = schBackBase - base
        lda schBackBase
        ldx schBack
        beq bs_cnt0
        sec
        sbc #15
bs_cnt0
        ldx schBack
        sta schCount,x
        ; swap front
        lda schBack
        sta schFront
        rts

; ---------------------------------------------------------------------
; spawn_enemies: countdown; on 0, spawn one enemy into a free slot 6..10
; from the wave tables, then reset the timer.
; ---------------------------------------------------------------------
spawn_enemies
        lda bossState
        beq se_go
        rts
se_go
        dec spawnTimer
        beq se_fire
        rts
se_fire
        ldx #6                  ; find free enemy slot
se_find
        cpx #11
        bcs se_reset            ; none free -> just reset timer
        lda vsActive,x
        beq se_spawn
        inx
        jmp se_find
se_spawn
        ldy spawnIndex
        lda #$54                ; X = 340 ($154): lo=$54, hi=1 (right edge)
        sta vsXlo,x
        lda #1
        sta vsXhi,x
        lda waveY,y
        sta vsY,x
        sta vsBaseY,x
        lda wavePattern,y
        sta vsPattern,x
        lda #0
        sta vsPhase,x
        sta vsState,x
        lda #ENEMY_COLOR
        sta vsColor,x
        lda #1
        sta vsActive,x
        sta vsVY,x              ; default zigzag velocity = +1
        iny                     ; advance wave index (wrap at waveN)
        cpy #waveN
        bcc se_idxok
        ldy #0
se_idxok
        sty spawnIndex
se_reset
        lda #SPAWN_INTERVAL
        sta spawnTimer
        rts

; ---------------------------------------------------------------------
; update_enemies: slots 6..10. Exploding -> count down & despawn.
; Alive -> move left by ENEMY_SPEED, despawn off left edge. Vertical
; movement by pattern is added in Task 2 (ue_vert is straight/no-op here).
; ---------------------------------------------------------------------
update_enemies
        lda bossState
        beq ue_go
        rts
ue_go
        ldx #6
ue_loop
        cpx #11
        bcc ue_notdone
        jmp ue_done
ue_notdone
        lda vsActive,x
        bne ue_isactive
        jmp ue_next
ue_isactive
        lda vsState,x
        beq ue_alive
        ; exploding: count down, despawn at 0
        dec vsExplodeTimer,x
        bne ue_next
        jsr ue_despawn
        jmp ue_next
ue_alive
        ; X -= ENEMY_SPEED (16-bit, move left)
        lda vsXlo,x
        sec
        sbc #ENEMY_SPEED
        sta vsXlo,x
        lda vsXhi,x
        sbc #0
        sta vsXhi,x
        ; off-left despawn: hi==0 and lo<20, or hi==$ff (underflow)
        lda vsXhi,x
        bne ue_xhi
        lda vsXlo,x
        cmp #20
        bcs ue_vert             ; still on screen -> vertical move
        jsr ue_despawn
        jmp ue_next
ue_xhi
        cmp #$ff                ; A = vsXhi
        bne ue_vert             ; hi==1 -> on right of screen
        jsr ue_despawn
        jmp ue_next
ue_vert
        lda vsPattern,x
        beq ue_next             ; 0 = straight -> no vertical
        cmp #1
        beq ue_sine
        ; --- pattern 2: zigzag (Y += vsVY, bounce [54,210]) ---
        lda vsY,x
        clc
        adc vsVY,x
        sta vsY,x
        cmp #70
        bcs ue_zz_top
        lda #70
        sta vsY,x
        jsr ue_negVY
        jmp ue_next
ue_zz_top
        cmp #211
        bcc ue_next
        lda #210
        sta vsY,x
        jsr ue_negVY
        jmp ue_next
ue_sine
        ; phase = (phase+1)&63; Y = vsBaseY + sineTable[phase]
        lda vsPhase,x
        clc
        adc #1
        and #63
        sta vsPhase,x
        tay
        lda sineTable,y
        clc
        adc vsBaseY,x
        sta vsY,x
        jmp ue_next
ue_next
        inx
        jmp ue_loop
ue_done
        rts

; despawn enemy in X: inactive + park Y off-screen
ue_despawn
        lda #0
        sta vsActive,x
        lda #255
        sta vsY,x
        rts

; negate vsVY[x] (zigzag bounce)
ue_negVY
        lda #0
        sec
        sbc vsVY,x
        sta vsVY,x
        rts

; ---------------------------------------------------------------------
; enemy_fire: countdown; on 0, fire a straight-left bullet from a live
; enemy (cycling via enemyFireIndex 6..10) into a free enemy-bullet slot
; (11..14). X = enemy-bullet slot, Y = enemy slot.
; ---------------------------------------------------------------------
enemy_fire
        lda bossState
        beq ef_go
        rts
ef_go
        dec enemyFireTimer
        beq ef_fire
        rts
ef_fire
        ldx #11                 ; find free enemy-bullet slot 11..14
ef_findbul
        cpx #15
        bcs ef_reset            ; none free
        lda vsActive,x
        beq ef_havebul
        inx
        jmp ef_findbul
ef_havebul
        ; scan up to 5 enemies starting at enemyFireIndex for a live one
        ldy enemyFireIndex
        lda #5
        sta ef_scan
ef_findenemy
        cpy #11                 ; wrap y into 6..10
        bcc ef_yok
        ldy #6
ef_yok
        lda vsActive,y
        beq ef_skipenemy
        lda vsState,y
        beq ef_spawn            ; live enemy at y
ef_skipenemy
        iny
        dec ef_scan
        bne ef_findenemy
        jmp ef_reset            ; no live enemy
ef_spawn
        lda vsXlo,y             ; spawn enemy bullet at enemy position
        sta vsXlo,x
        lda vsXhi,y
        sta vsXhi,x
        lda vsY,y
        sta vsY,x
        lda #EBULLET_COLOR
        sta vsColor,x
        lda #1
        sta vsActive,x
        iny                     ; advance fire index past this enemy (wrap)
        cpy #11
        bcc ef_idxok
        ldy #6
ef_idxok
        sty enemyFireIndex
ef_reset
        lda #ENEMY_FIRE_INTERVAL
        sta enemyFireTimer
        rts

; place the 5 boss pieces (slots 6..10) at the anchor: same X, Y spread by bossOffY.
; color = white while bossFlash>0, else BOSS_COLOR.
boss_place_pieces
        ldx #0                  ; piece index 0..4
bpp_loop
        cpx #5
        bcs bpp_done
        txa
        clc
        adc #6
        tay                     ; y = slot 6..10
        lda bossXlo
        sta vsXlo,y
        lda bossXhi
        sta vsXhi,y
        lda bossY
        clc
        adc bossOffY,x          ; signed Y offset
        sta vsY,y
        lda bossFlash
        beq bpp_normalcol
        lda #1                  ; white (flash)
        jmp bpp_setcol
bpp_normalcol
        lda #BOSS_COLOR
bpp_setcol
        sta vsColor,y
        lda #1
        sta vsActive,y
        lda #0
        sta vsState,y
        inx
        jmp bpp_loop
bpp_done
        rts

; bob the anchor Y around bossYCenter via the sine table
boss_bob
        inc bossPhase
        lda bossPhase
        and #63
        sta bossPhase
        tay
        lda sineTable,y
        clc
        adc bossYCenter
        sta bossY
        rts

; boss_fire: on timer, spawn straight-left bullets into free slots 11..14
; from successive boss-piece Y positions (a vertical volley).
boss_fire
        dec bossFireTimer
        beq bf_fire
        rts
bf_fire
        ldx #11                 ; enemy-bullet slot
        ldy #6                  ; boss piece slot
bf_loop
        cpx #15
        bcs bf_done
        lda vsActive,x
        bne bf_nextbul          ; bullet slot occupied
        lda vsXlo,y             ; spawn from piece y
        sta vsXlo,x
        lda vsXhi,y
        sta vsXhi,x
        lda vsY,y
        sta vsY,x
        lda #EBULLET_COLOR
        sta vsColor,x
        lda #1
        sta vsActive,x
        iny                     ; next piece (wrap 6..10)
        cpy #11
        bcc bf_nextbul
        ldy #6
bf_nextbul
        inx
        jmp bf_loop
bf_done
        lda #BOSS_FIRE_INTERVAL
        sta bossFireTimer
        rts

; boss_take_hit: despawn the player bullet (slot X), drain HP, flash;
; HP 0 -> dying. Only counts while fighting.
boss_take_hit
        lda #0
        sta vsActive,x
        lda #255
        sta vsY,x
        ; fall through: drain HP without another despawn
boss_drain_hp
        lda bossState
        cmp #BS_FIGHT
        bne bth_ret
        dec bossHP
        lda #BOSS_FLASH_FRAMES
        sta bossFlash
        lda bossHP
        bne bth_ret
        lda #BS_DYING
        sta bossState
        lda #BOSS_DEATH_FRAMES
        sta bossDeathTimer
bth_ret
        rts

; boss_spawn: initialise an entering boss
boss_spawn
        lda #BS_ENTER
        sta bossState
        lda #BOSS_HP
        sta bossHP
        lda #$54                ; X = 340 (hi=1, lo=$54)
        sta bossXlo
        lda #1
        sta bossXhi
        lda #130
        sta bossY
        sta bossYCenter
        lda #0
        sta bossPhase
        sta bossFlash
        lda #BOSS_FIRE_INTERVAL
        sta bossFireTimer
        jsr sfx_boss
        jsr boss_place_pieces
        rts

; boss_update: state machine, called each frame from main_loop.
boss_update
        lda bossState
        bne bu_active
        ; inactive: trigger after enough kills
        lda killCount
        cmp #BOSS_KILL_THRESHOLD
        bcc bu_ret
        jsr boss_spawn
bu_ret
        rts
bu_active
        cmp #BS_ENTER
        beq bu_enter
        cmp #BS_FIGHT
        beq bu_fight
        jmp bu_dying            ; BS_DYING
bu_enter
        lda bossXlo             ; slide left (hi stays 1 from 340->300)
        sec
        sbc #BOSS_ENTER_SPEED
        sta bossXlo
        lda bossXhi
        sbc #0
        sta bossXhi
        lda bossXlo
        cmp #$2d                ; lo < $2d -> reached fight X (300=$12c)
        bcs bu_enter_place
        lda #BS_FIGHT
        sta bossState
bu_enter_place
        jsr boss_place_pieces
        rts
bu_fight
        jsr boss_bob
        jsr boss_fire
        lda bossFlash
        beq bu_fight_place
        dec bossFlash
bu_fight_place
        jsr boss_place_pieces
        rts

bu_dying
        dec bossDeathTimer
        beq bd_done
        ; keep pieces flashing white during the explosion
        lda #BOSS_FLASH_FRAMES
        sta bossFlash
        jsr boss_place_pieces
        rts
bd_done
        ; despawn boss pieces
        ldx #6
bd_clear
        cpx #11
        bcs bd_cleared
        lda #0
        sta vsActive,x
        lda #255
        sta vsY,x
        inx
        jmp bd_clear
bd_cleared
        lda #0
        sta bossState
        sta killCount
        jsr sfx_explosion
        ; +1000 score bonus (BCD, IRQ-safe)
        php
        sei
        sed
        clc
        lda score+1
        adc #$10
        sta score+1
        lda score+2
        adc #0
        sta score+2
        plp
        rts

; ---------------------------------------------------------------------
; update_enemy_bullets: slots 11..14 move LEFT; despawn off the left edge.
; ---------------------------------------------------------------------
update_enemy_bullets
        ldx #11
ueb_loop
        cpx #15
        bcs ueb_done
        lda vsActive,x
        beq ueb_next
        lda vsXlo,x             ; X -= EBULLET_SPEED (16-bit, move left)
        sec
        sbc #EBULLET_SPEED
        sta vsXlo,x
        lda vsXhi,x
        sbc #0
        sta vsXhi,x
        lda vsXhi,x             ; off-left despawn
        bne ueb_hi
        lda vsXlo,x
        cmp #8
        bcs ueb_next            ; lo>=8 -> on screen
        jsr ue_despawn
        jmp ueb_next
ueb_hi
        cmp #$ff                ; A = vsXhi; $ff = underflow -> despawn; 1 = on right
        bne ueb_next
        jsr ue_despawn
ueb_next
        inx
        jmp ueb_loop
ueb_done
        rts

; update_bullets: edge-based firing with charge state; move live bullets
; right; despawn past the right edge (X > 344 = $158).
update_bullets
        ; --- exploding player: no fire, reset charge, normal ship color ---
        lda playerState
        cmp #PS_EXPLODE
        bne ub_input
        lda #0
        sta chargeTimer
        sta prevSpace
        jsr restore_ship_color
        jmp ub_move
ub_input
        lda keyrow7
        and #%00010000          ; Space, active-low: 0 = DOWN
        bne ub_up
        ; ---- Space DOWN this frame ----
        lda prevSpace
        bne ub_hold             ; already down -> charging
        jsr fire_normal_shot    ; rising edge -> one shot now
        lda #0
        sta chargeTimer
        jmp ub_downend
ub_hold
        lda chargeTimer
        cmp #CHARGE_MAX
        bcs ub_downend          ; capped
        inc chargeTimer
ub_downend
        lda #1
        sta prevSpace
        jsr charge_feedback
        jmp ub_move
ub_up
        ; ---- Space UP this frame ----
        lda prevSpace
        beq ub_move             ; was already up -> nothing to do
        lda chargeTimer
        cmp #CHARGE_THRESHOLD
        bcc ub_upclear          ; not enough charge -> no beam
        jsr fire_beam
ub_upclear
        lda #0
        sta chargeTimer
        sta prevSpace
        jsr restore_ship_color
        jmp ub_move
ub_move
        ; move all live bullets (slots 0..5) right by 4; despawn past $158
        ldx #0
ub_mloop
        cpx #6
        bcs ub_done
        lda vsActive,x
        beq ub_mnext
        lda vsXlo,x
        clc
        adc #4
        sta vsXlo,x
        lda vsXhi,x
        adc #0
        sta vsXhi,x
        ; despawn if X > 344 ($158): hi>=2, or (hi==1 and lo>=$59)
        lda vsXhi,x
        cmp #2
        bcs ub_kill
        cmp #1
        bcc ub_mnext            ; hi==0 -> on screen
        lda vsXlo,x
        cmp #$59
        bcc ub_mnext
ub_kill
        lda #0
        sta vsActive,x
        lda #0
        sta vsExpand,x
        lda #255
        sta vsY,x               ; park (sorts last)
ub_mnext
        inx
        jmp ub_mloop
ub_done
        rts

; spawn_player_bullet: find free slot 0..5, spawn at ship nose using
; bulColor / bulExpand. Plays sfx_fire. No-op if no free slot.
spawn_player_bullet
        ldx #0
spb_find
        cpx #6
        bcs spb_none
        lda vsActive,x
        beq spb_do
        inx
        jmp spb_find
spb_do
        lda player_x
        clc
        adc #24
        sta vsXlo,x
        lda player_x_hi
        adc #0
        sta vsXhi,x
        lda player_y
        clc
        adc #8
        sta vsY,x
        lda bulColor
        sta vsColor,x
        lda bulExpand
        sta vsExpand,x
        lda #1
        sta vsActive,x
        jsr sfx_fire
spb_none
        rts

fire_normal_shot
        lda #7                  ; yellow
        sta bulColor
        lda #0
        sta bulExpand
        jsr spawn_player_bullet
        rts

fire_beam
        lda #BEAM_COLOR
        sta bulColor
        lda #1
        sta bulExpand
        jsr spawn_player_bullet
        rts

; charge_feedback: pulse SP0COL while charging, steady READY at threshold.
charge_feedback
        lda chargeTimer
        cmp #CHARGE_THRESHOLD
        bcs cf_ready
        lda chargeTimer
        and #%00001000          ; ~8-frame pulse
        bne cf_alt
        lda #SHIP_COLOR_NORMAL
        sta SP0COL
        rts
cf_alt
        lda #SHIP_COLOR_CHARGE
        sta SP0COL
        rts
cf_ready
        lda #SHIP_COLOR_READY
        sta SP0COL
        rts

restore_ship_color
        lda #SHIP_COLOR_NORMAL
        sta SP0COL
        rts

; ---------------------------------------------------------------------
; check_hits: each live bullet (0..5) vs each alive enemy (6..10).
; bounding box |dX|<HITW and |dY|<HITH -> bullet despawns, enemy explodes.
; X = bullet slot, Y = enemy slot.
; ---------------------------------------------------------------------
check_hits
        ldx #0
ch_bloop
        cpx #6
        bcc ch_notdone1
        jmp ch_done
ch_notdone1
        lda vsActive,x
        bne ch_notbnext1
        jmp ch_bnext
ch_notbnext1
        ldy #6
ch_eloop
        cpy #11
        bcc ch_notbnext2
        jmp ch_bnext
ch_notbnext2
        lda vsActive,y
        bne ch_notenext1
        jmp ch_enext
ch_notenext1
        lda vsState,y
        beq ch_state0
        jmp ch_enext            ; enemy already exploding
ch_state0
        ; --- 16-bit dX = enemyX - bulletX ---
        lda vsXlo,y
        sec
        sbc vsXlo,x
        sta chDlo
        lda vsXhi,y
        sbc vsXhi,x
        sta chDhi
        bpl ch_xpos             ; dX >= 0
        ; negate 16-bit
        lda #0
        sec
        sbc chDlo
        sta chDlo
        lda #0
        sbc chDhi
        sta chDhi
ch_xpos
        lda chDhi
        bne ch_enext            ; |dX| >= 256 -> no hit
        lda chDlo
        cmp #HITW
        bcs ch_enext            ; |dX| >= HITW -> no hit
        ; --- 8-bit |dY| = |enemyY - bulletY| ---
        lda vsY,y
        sec
        sbc vsY,x
        bpl ch_ypos
        eor #$ff
        clc
        adc #1                  ; two's complement abs
ch_ypos
        cmp #HITH
        bcs ch_enext            ; |dY| >= HITH -> no hit
        ; --- HIT ---
        lda bossState
        beq ch_normalkill       ; no boss -> normal enemy kill
        jsr boss_take_hit       ; boss piece hit: drain HP, despawn bullet X
        jmp ch_bnext
ch_normalkill
        jsr kill_enemy_y        ; explode enemy Y + score + killCount
        lda #0
        sta vsActive,x          ; despawn this bullet
        lda #255
        sta vsY,x
        jmp ch_bnext            ; this bullet consumed -> next bullet
ch_enext
        iny
        jmp ch_eloop
ch_bnext
        inx
        jmp ch_bloop
ch_done
        rts

; kill_enemy_y: Y = enemy slot. Explode + SFX + BCD score + killCount.
; Preserves X and Y.
kill_enemy_y
        lda #1
        sta vsState,y
        lda #EXPLODE_FRAMES
        sta vsExplodeTimer,y
        lda #EXPLODE_COLOR
        sta vsColor,y
        jsr sfx_explosion
        php
        sei
        sed
        clc
        lda score
        adc #SCORE_PER_KILL
        sta score
        lda score+1
        adc #0
        sta score+1
        lda score+2
        adc #0
        sta score+2
        plp
        inc killCount
        rts

; =====================================================================
;  SCROLL STEP  (once per frame)
;  - always: build a slice of the back buffer
;  - fine_x 7..1: just decrement and set $D016
;  - fine_x 0:    flip buffers, reset fine to 7, reset build_row
; =====================================================================
scroll_step
        jsr build_back_slice        ; spread the heavy work every frame

        dec fine_x
        bpl just_set_fine           ; fine_x still 0..6 -> set $D016

        ; --- coarse frame: flip to freshly-built back buffer ----------
        jsr flip_buffers
        jsr shift_color_ram         ; bring color RAM in line (sliced below*)
        jsr inject_color_column     ; new right-edge color column
        jsr advance_map             ; consume one map column

        lda #7
        sta fine_x
        lda #2
        sta build_row

just_set_fine
        rts

; =====================================================================
;  BUILD BACK SLICE
;  Build ROWS_PER_FRAME rows of the back buffer as:
;     back[row][0..38] = front[row][1..39]      (shift left one col)
;     back[row][39]    = map column tile for row (fresh right edge)
;  build_row tracks progress 0..24 across the char-step.
; =====================================================================
build_back_slice
        lda #ROWS_PER_FRAME
        sta rpf_left
bbs_loop
        ldx build_row
        cpx #25
        bcs bbs_done                ; all 25 rows built this char-step

        ; zp_fsrc = front row base, zp_bdst = back row base
        jsr front_row_addr          ; uses X = build_row
        jsr back_row_addr           ; uses X = build_row

        ; back[0..38] = front[1..39]
        ldx #0
bbs_col
        ldy bbs_srcidx,x            ; y = col+1  (1..39)
        lda (zp_fsrc),y
        ldy bbs_dstidx,x            ; y = col    (0..38)
        sta (zp_bdst),y
        inx
        cpx #39
        bne bbs_col

        ; back[39] = cached right-edge tile for this row
        ldx build_row
        lda map_rightcol_cache,x
        ldy #39
        sta (zp_bdst),y

        inc build_row
        dec rpf_left
        bne bbs_loop
bbs_done
        rts

rpf_left !byte ROWS_PER_FRAME

; index tables for the column copy (avoids inx/iny juggling above)
bbs_srcidx !for c,0,38 { !byte c+1 }
bbs_dstidx !for c,0,38 { !byte c }

; =====================================================================
;  FLIP BUFFERS: point VIC at the back buffer, swap front/back flag
; =====================================================================
flip_buffers
        lda front_is_a
        beq fb_make_a_front         ; currently B front -> make A front
        ; A is front -> show B
        lda #D18_B
        sta VICMEM
        lda #0
        sta front_is_a
        rts
fb_make_a_front
        lda #D18_A
        sta VICMEM
        lda #1
        sta front_is_a
        rts

; =====================================================================
;  ADDRESS HELPERS
;  front_row_addr: zp_fsrc = (front buffer) + row*40, row in X
;  back_row_addr:  zp_bdst = (back  buffer) + row*40, row in X
; =====================================================================
front_row_addr
        lda front_is_a
        bne fra_a
        ; front = B
        lda bufb_lo,x
        sta zp_fsrc
        lda bufb_hi,x
        sta zp_fsrc+1
        rts
fra_a
        lda bufa_lo,x
        sta zp_fsrc
        lda bufa_hi,x
        sta zp_fsrc+1
        rts

back_row_addr
        lda front_is_a
        bne bra_back_is_b
        ; front = B -> back = A
        lda bufa_lo,x
        sta zp_bdst
        lda bufa_hi,x
        sta zp_bdst+1
        rts
bra_back_is_b
        lda bufb_lo,x
        sta zp_bdst
        lda bufb_hi,x
        sta zp_bdst+1
        rts

; =====================================================================
;  COLOR RAM SHIFT  (sliced)  -- placeholder fixed-color this stage
;  For now color is uniform per tile, so we don't truly need to shift;
;  we keep a stub that maintains a static colored floor/sky split.
; =====================================================================
shift_color_ram
        rts                         ; (stage 1.5: color handled statically)

inject_color_column
        rts

; =====================================================================
;  MAP ADVANCE + RIGHT-COLUMN CACHE
;  We cache the 25 tiles of the column that will appear on the right edge
;  so build_back_slice can read them by row index cheaply.
; =====================================================================
advance_map
        ; advance zp_map by 25 (one column), wrap at map_end
        clc
        lda zp_map
        adc #25
        sta zp_map
        lda zp_map+1
        adc #0
        sta zp_map+1
        lda zp_map+1
        cmp #>map_end
        bcc am_cache
        bne am_wrap
        lda zp_map
        cmp #<map_end
        bcc am_cache
am_wrap
        lda #<map_data
        sta zp_map
        lda #>map_data
        sta zp_map+1
am_cache
        jsr cache_right_column
        rts

cache_right_column
        ldy #0
crc_loop
        lda (zp_map),y
        sty crc_tmp
        ldx crc_tmp
        sta map_rightcol_cache,x
        iny
        cpy #25
        bne crc_loop
        rts
crc_tmp !byte 0

map_rightcol_cache
        !fill 25, 0

; =====================================================================
;  INITIAL FILL: BUF_A from first 40 map columns; cache col 40
; =====================================================================
fill_front_from_map
        lda #<map_data
        sta zp_map
        lda #>map_data
        sta zp_map+1

        lda #0
        sta ff_col
ff_col_loop
        lda #0
        sta ff_row
ff_row_loop
        ldx ff_row
        lda bufa_lo,x
        sta zp_dst
        lda bufa_hi,x
        sta zp_dst+1
        lda zp_dst
        clc
        adc ff_col
        sta zp_dst
        bcc ff_nohi
        inc zp_dst+1
ff_nohi
        ldy ff_row
        lda (zp_map),y
        ldy #0
        sta (zp_dst),y

        ; color RAM: static sky/floor split
        ldx ff_row
        lda crow_lo,x
        sta zp_dst
        lda crow_hi,x
        sta zp_dst+1
        lda zp_dst
        clc
        adc ff_col
        sta zp_dst
        bcc ff_cnohi
        inc zp_dst+1
ff_cnohi
        ldx ff_row
        lda floor_color_tbl,x
        ldy #0
        sta (zp_dst),y

        inc ff_row
        lda ff_row
        cmp #25
        bne ff_row_loop

        clc
        lda zp_map
        adc #25
        sta zp_map
        lda zp_map+1
        adc #0
        sta zp_map+1

        inc ff_col
        lda ff_col
        cmp #40
        bne ff_col_loop

        jsr cache_right_column      ; cache column 40 for first right edge
        rts
ff_col !byte 0
ff_row !byte 0

; =====================================================================
;  COPY BUFFER A -> BUFFER B  (one-time at init so both start equal)
; =====================================================================
copy_a_to_b
        lda #<BUF_A
        sta zp_fsrc
        lda #>BUF_A
        sta zp_fsrc+1
        lda #<BUF_B
        sta zp_bdst
        lda #>BUF_B
        sta zp_bdst+1
        ldx #4                      ; 4 pages covers 1000 bytes (+pad)
        ldy #0
cab_loop
        lda (zp_fsrc),y
        sta (zp_bdst),y
        iny
        bne cab_loop
        inc zp_fsrc+1
        inc zp_bdst+1
        dex
        bne cab_loop
        rts

; =====================================================================
;  SPRITE INIT  (one-time)
;   sprite 0 = player ship (multicolor), sprites 1-7 share mux_shape (hi-res)
;   pointers MUST be set in BOTH screen buffers.
; =====================================================================
SPENA   = $d015              ; sprite enable
SPMC    = $d01c              ; sprite multicolor select
XXPAND  = $d01d              ; sprite X expand
YXPAND  = $d017              ; sprite Y expand
SPBGPR  = $d01b              ; sprite-background priority
SPMC0   = $d025              ; shared sprite multicolor 0
SPMC1   = $d026              ; shared sprite multicolor 1
SP0COL  = $d027              ; sprite 0 color
SP1COL  = $d028              ; sprite 1 color

PLAYER_PTR = 208             ; $3400 / 64

init_sprites
        ; --- sprite 0 (player) pointer in both buffers ---
        lda #PLAYER_PTR             ; 208 = $3400/64
        sta BUF_A+$3f8
        sta BUF_B+$3f8
        ; --- sprites 1..7 all point at the shared mux shape, both buffers ---
        lda #209                    ; $3440/64
        ldx #1
ip_loop
        sta BUF_A+$3f8,x
        sta BUF_B+$3f8,x
        inx
        cpx #8
        bne ip_loop

        lda #%11111111              ; enable all 8 sprites
        sta SPENA
        lda #%00000001              ; sprite 0 multicolor; sprites 1-7 hi-res
        sta SPMC
        ; --- no expansion, sprites in front of background ---
        lda #0
        sta XXPAND
        sta YXPAND
        sta SPBGPR

        ; --- colors (contrast against blue bg) ---
        lda #1               ; hull = white
        sta SP0COL
        lda #7               ; shared MC0 = yellow (engine)
        sta SPMC0
        lda #2               ; shared MC1 = red (cockpit)
        sta SPMC1
        lda #7               ; sprite 1 default color (yellow)
        sta SP1COL

        ; --- CIA1 data direction for keyboard scan (defensive) ---
        lda #$ff
        sta $dc02            ; port A all output (row select)
        lda #$00
        sta $dc03            ; port B all input (column read)

        ; --- start position comes from player_x/player_y vars ---
        jsr write_player_sprite
        rts

; =====================================================================
;  COLORS
; =====================================================================
set_colors
        lda #6
        sta BGCOL0
        lda #14
        sta BGCOL1
        lda #11
        sta BGCOL2
        rts

; =====================================================================
;  CHARSET (same 4 tiles as stage 1)
; =====================================================================
build_charset
        lda #<CHARSET
        sta zp_dst
        lda #>CHARSET
        sta zp_dst+1
        ldx #8
        ldy #0
bc_clear
        lda #0
        sta (zp_dst),y
        iny
        bne bc_clear
        inc zp_dst+1
        dex
        bne bc_clear

        lda #%00110000
        sta CHARSET + 1*8 + 3

        ldx #0
bc_block
        lda #%11111111
        sta CHARSET + 2*8, x
        inx
        cpx #8
        bne bc_block

        lda #%10101010
        sta CHARSET + 3*8 + 0
        sta CHARSET + 3*8 + 1
        sta CHARSET + 3*8 + 2
        sta CHARSET + 3*8 + 3
        lda #%11111111
        sta CHARSET + 3*8 + 4
        sta CHARSET + 3*8 + 5
        sta CHARSET + 3*8 + 6
        sta CHARSET + 3*8 + 7

        ; --- digit glyphs 0-9 at screen codes 16..25 ---
        ldx #0
bc_dig
        lda digit_glyphs,x
        sta CHARSET + DIGIT_BASE*8, x
        inx
        cpx #80
        bne bc_dig
        ; --- letter glyphs at screen codes 26.. (S c o r e h i p s l f t :) ---
        ldx #0
bc_let
        lda letter_glyphs,x
        sta CHARSET + 26*8, x
        inx
        cpx #104
        bne bc_let
        rts

; sid_init: master volume max, all gates off, clear sfx timers
sid_init
        lda #$0f
        sta $d418               ; volume 15, no filter
        lda #0
        sta $d404               ; V1 control (gate off)
        sta $d40b               ; V2 control
        sta $d412               ; V3 control
        sta sfxTimer+0
        sta sfxTimer+1
        sta sfxTimer+2
        rts

; sound_voice: advance one voice (X = 0,1,2). Sweep freq, write SID, gate
; off when the timer expires. Uses $fd/$fe as the SID voice pointer.
sound_voice
        lda sfxTimer,x
        bne sv_active
        rts                     ; idle
sv_active
        lda sidbase_lo,x
        sta $fd
        lda #$d4
        sta $fe
        clc
        lda sfxFreqLo,x
        adc sfxSweepLo,x
        sta sfxFreqLo,x
        ldy #0
        sta ($fd),y             ; SID freq lo
        lda sfxFreqHi,x
        adc sfxSweepHi,x
        sta sfxFreqHi,x
        ldy #1
        sta ($fd),y             ; SID freq hi
        dec sfxTimer,x
        bne sv_ret
        lda sfxRelease,x        ; timer hit 0 -> gate off (release)
        ldy #4
        sta ($fd),y
sv_ret
        rts

; sound_update: advance all three voices (called once per frame)
sound_update
        ldx #0
        jsr sound_voice
        ldx #1
        jsr sound_voice
        ldx #2
        jsr sound_voice
        rts

; sfx_fire: short laser "pew" on V1
sfx_fire
        lda #$09
        sta $d405               ; AD: attack 0, decay 9
        lda #$00
        sta $d406               ; SR: sustain 0, release 0
        lda #$00
        sta sfxFreqLo+0
        sta $d400
        lda #$28
        sta sfxFreqHi+0
        sta $d401               ; start freq $2800
        lda #$00
        sta sfxSweepLo+0
        lda #$fd
        sta sfxSweepHi+0        ; sweep -$0300/frame
        lda #$20
        sta sfxRelease+0        ; saw, gate off
        lda #$21
        sta $d404               ; saw + gate on
        lda #6
        sta sfxTimer+0
        rts

; sfx_explosion: noise "boom" on V2
sfx_explosion
        lda #$0a
        sta $d40c               ; V2 AD
        lda #$00
        sta $d40d               ; V2 SR
        lda #$00
        sta sfxFreqLo+1
        sta $d407
        lda #$18
        sta sfxFreqHi+1
        sta $d408               ; start freq $1800
        lda #$00
        sta sfxSweepLo+1
        lda #$ff
        sta sfxSweepHi+1        ; sweep -$0100/frame
        lda #$80
        sta sfxRelease+1        ; noise, gate off
        lda #$81
        sta $d40b               ; noise + gate on
        lda #16
        sta sfxTimer+1
        rts

; sfx_hit: damage "thud" on V3
sfx_hit
        lda #$0a
        sta $d413               ; V3 AD
        lda #$00
        sta $d414               ; V3 SR
        lda #$00
        sta $d410               ; pulse width lo
        lda #$08
        sta $d411               ; pulse width hi (~50%)
        lda #$00
        sta sfxFreqLo+2
        sta $d40e
        lda #$0a
        sta sfxFreqHi+2
        sta $d40f               ; start freq $0a00
        lda #$c0
        sta sfxSweepLo+2
        lda #$ff
        sta sfxSweepHi+2        ; sweep -$0040/frame
        lda #$40
        sta sfxRelease+2        ; pulse, gate off
        lda #$41
        sta $d412               ; pulse + gate on
        lda #20
        sta sfxTimer+2
        rts

; sfx_boss: ominous rising warning sting on V3
sfx_boss
        lda #$08
        sta $d413               ; V3 AD
        lda #$00
        sta $d414               ; V3 SR
        lda #$00
        sta $d410
        lda #$08
        sta $d411               ; pulse width ~50%
        lda #$00
        sta sfxFreqLo+2
        sta $d40e
        lda #$04
        sta sfxFreqHi+2
        sta $d40f               ; start freq $0400 (low)
        lda #$30
        sta sfxSweepLo+2
        lda #$00
        sta sfxSweepHi+2        ; sweep +$0030/frame (rising)
        lda #$40
        sta sfxRelease+2
        lda #$41
        sta $d412               ; pulse + gate on
        lda #30
        sta sfxTimer+2
        rts

; =====================================================================
;  ROW ADDRESS TABLES
; =====================================================================
bufa_lo  !for row,0,24 { !byte <(BUF_A + row*40) }
bufa_hi  !for row,0,24 { !byte >(BUF_A + row*40) }
bufb_lo  !for row,0,24 { !byte <(BUF_B + row*40) }
bufb_hi  !for row,0,24 { !byte >(BUF_B + row*40) }
crow_lo  !for row,0,24 { !byte <(COLORRAM + row*40) }
crow_hi  !for row,0,24 { !byte >(COLORRAM + row*40) }

; static color per row: sky rows light, floor rows brown-ish
floor_color_tbl
        !for row,0,24 {
            !if row >= 23 { !byte 8 } else {
                !if row = 22 { !byte 7 } else { !byte 14 }
            }
        }

digit_glyphs
        !byte %00111100,%01100110,%01101110,%01110110,%01100110,%01100110,%00111100,%00000000  ; 0
        !byte %00011000,%00111000,%00011000,%00011000,%00011000,%00011000,%01111110,%00000000  ; 1
        !byte %00111100,%01100110,%00000110,%00001100,%00110000,%01100000,%01111110,%00000000  ; 2
        !byte %00111100,%01100110,%00000110,%00011100,%00000110,%01100110,%00111100,%00000000  ; 3
        !byte %00001100,%00011100,%00111100,%01101100,%01111110,%00001100,%00001100,%00000000  ; 4
        !byte %01111110,%01100000,%01111100,%00000110,%00000110,%01100110,%00111100,%00000000  ; 5
        !byte %00111100,%01100110,%01100000,%01111100,%01100110,%01100110,%00111100,%00000000  ; 6
        !byte %01111110,%01100110,%00001100,%00011000,%00011000,%00011000,%00011000,%00000000  ; 7
        !byte %00111100,%01100110,%01100110,%00111100,%01100110,%01100110,%00111100,%00000000  ; 8
        !byte %00111100,%01100110,%01100110,%00111110,%00000110,%01100110,%00111100,%00000000  ; 9

; letter glyphs at codes 26.. : S c o r e h i p s l f t  :
letter_glyphs
        !byte %00111100,%01100110,%01100000,%00111100,%00000110,%01100110,%00111100,%00000000  ; 26 S
        !byte %00000000,%00000000,%00111100,%01100000,%01100000,%01100000,%00111100,%00000000  ; 27 c
        !byte %00000000,%00000000,%00111100,%01100110,%01100110,%01100110,%00111100,%00000000  ; 28 o
        !byte %00000000,%00000000,%01101100,%01110000,%01100000,%01100000,%01100000,%00000000  ; 29 r
        !byte %00000000,%00000000,%00111100,%01100110,%01111110,%01100000,%00111100,%00000000  ; 30 e
        !byte %01100000,%01100000,%01111100,%01100110,%01100110,%01100110,%01100110,%00000000  ; 31 h
        !byte %00011000,%00000000,%00111000,%00011000,%00011000,%00011000,%00111100,%00000000  ; 32 i
        !byte %00000000,%00000000,%01111100,%01100110,%01111100,%01100000,%01100000,%00000000  ; 33 p
        !byte %00000000,%00000000,%00111110,%01100000,%00111100,%00000110,%01111100,%00000000  ; 34 s
        !byte %00111000,%00011000,%00011000,%00011000,%00011000,%00011000,%00111100,%00000000  ; 35 l
        !byte %00011100,%00110000,%01111100,%00110000,%00110000,%00110000,%00110000,%00000000  ; 36 f
        !byte %00110000,%00110000,%01111100,%00110000,%00110000,%00110110,%00011100,%00000000  ; 37 t
        !byte %00000000,%00011000,%00011000,%00000000,%00000000,%00011000,%00011000,%00000000  ; 38 :

; HUD label strings (screen codes; space = code 0)
label_score !byte 26,27,28,29,30,38,0              ; "Score: "
label_ships !byte 26,31,32,33,34,0,35,30,36,37,38,0  ; "Ships left: "

; =====================================================================
;  MAP DATA (column-major, 25 bytes/column), same generator as stage 1
;  Relocated to $2800 (above charset) so it never overlaps BUF_B.
; =====================================================================
* = $2800
map_data
        !for col, 0, 119 {
            !for r, 0, 21 {
                !if (((col*7 + r*13) & 31) = 0) { !byte 1 } else { !byte 0 }
            }
            !if ((col & 7) = 0) { !byte 2 } else { !byte 0 }
            !byte 3
            !byte 3
        }
map_end

; ---- player movement state ----
keyrow4     !byte $ff        ; cached $DC01 for row $EF (I,J,K)
keyrow5     !byte $ff        ; cached $DC01 for row $DF (L)
keyrow7     !byte $ff        ; cached $DC01 for row $7F (space)
player_x    !byte 60         ; sprite 0 X, low 8 bits
player_x_hi !byte 0          ; sprite 0 X, bit 8 (0 or 1)
player_y    !byte 120        ; sprite 0 Y

; =====================================================================
;  SPRITE DATA  (VIC bank 0, 64-byte aligned)
;  Player: 24x21 multicolor wedge pointing right.
;   bit-pairs: 00=transparent 01=SPMC0(yellow) 10=SP0COL(white) 11=SPMC1(red)
; =====================================================================
* = $3400
player_sprite
        !byte $00,$00,$00   ; row 0
        !byte $00,$00,$00   ; row 1
        !byte $00,$00,$00   ; row 2
        !byte $00,$00,$00   ; row 3
        !byte $00,$00,$00   ; row 4
        !byte $a0,$00,$00   ; row 5
        !byte $aa,$00,$00   ; row 6
        !byte $6a,$a0,$00   ; row 7
        !byte $6a,$ea,$00   ; row 8
        !byte $6a,$fa,$a8   ; row 9
        !byte $6a,$fa,$aa   ; row 10
        !byte $6a,$fa,$a8   ; row 11
        !byte $6a,$ea,$00   ; row 12
        !byte $6a,$a0,$00   ; row 13
        !byte $aa,$00,$00   ; row 14
        !byte $a0,$00,$00   ; row 15
        !byte $00,$00,$00   ; row 16
        !byte $00,$00,$00   ; row 17
        !byte $00,$00,$00   ; row 18
        !byte $00,$00,$00   ; row 19
        !byte $00,$00,$00   ; row 20
        !byte $00           ; pad to 64 bytes

* = $3440
mux_shape                    ; shared shape for all multiplexed sprites (ptr 209)
        !fill 8*3, 0         ; rows 0-7 blank
        !byte $00,$7e,$00    ; row 8   (0111 1110)
        !byte $00,$ff,$00    ; row 9
        !byte $00,$ff,$00    ; row 10
        !byte $00,$ff,$00    ; row 11
        !byte $00,$7e,$00    ; row 12
        !fill 8*3, 0         ; rows 13-20 blank
        !byte $00            ; pad to 64

; =====================================================================
;  VIRTUAL SPRITE TABLE + MUX STATE  (free space $3480-$37FF, below BUF_B $3800)
; =====================================================================
* = $3480
vsXlo    !fill 15,0       ; virtual sprite X low (9-bit X = vsXhi:vsXlo)
vsXhi    !fill 15,0       ; virtual sprite X bit8 (0/1)
vsY      !fill 15,255     ; virtual sprite Y (255 = parked/inactive sorts last)
vsColor  !fill 15,0       ; per-slot hi-res color
vsActive !fill 15,0       ; 0=free, 1=live
vsVY     !fill 15,0       ; signed vertical velocity
vsPattern !fill 15,0       ; 0=straight 1=sine 2=zigzag
vsPhase   !fill 15,0       ; sine table index
vsState   !fill 15,0       ; 0=alive 1=exploding
vsExplodeTimer !fill 15,0  ; frames left in explosion
vsBaseY   !fill 15,0       ; sine vertical center
vsExpand !fill 15,0        ; 1 = X-expanded piercing beam; 0 = normal
spawnTimer !byte 30
spawnIndex !byte 0
enemyFireTimer !byte 30
enemyFireIndex !byte 6
ef_scan        !byte 0
chDlo      !byte 0        ; check_hits scratch: dX low byte
chDhi      !byte 0        ; check_hits scratch: dX high byte
waveY       !byte 90,120,150,100,140,95,170,110
wavePattern !byte 0,1,2,1,0,2,1,0    ; straight/sine/zigzag mix
waveN = 8
sineTable
        !byte $00,$02,$03,$05,$06,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,$0f,$10,$10
        !byte $10,$10,$10,$0f,$0f,$0e,$0d,$0c,$0b,$0a,$09,$08,$06,$05,$03,$02
        !byte $00,$fe,$fd,$fb,$fa,$f8,$f7,$f6,$f5,$f4,$f3,$f2,$f1,$f1,$f0,$f0
        !byte $f0,$f0,$f0,$f1,$f1,$f2,$f3,$f4,$f5,$f6,$f7,$f8,$fa,$fb,$fd,$fe
sortIdx  !byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14   ; slot order by Y (persists, re-sorted)
; schedule double buffer: buffer 0 = entries 0..14, buffer 1 = entries 15..29
schY     !fill 30,0
schXlo   !fill 30,0
schXhi   !fill 30,0
schColor !fill 30,0
schExpand !fill 30,0       ; per-schedule-entry X-expand flag (parallels schColor)
schCount !byte 0,0        ; [buffer] live count
schFront !byte 0          ; buffer the IRQ reads (0/1)
; multiplex IRQ state
muxIdx   !byte 0          ; current schedule array index (already buffer-offset)
muxEnd   !byte 0          ; stop index (base+count)
muxHW    !byte 1          ; next hardware sprite (1..7, round robin)
; bullet fire cooldown
fireCool !byte 0
prevSpace   !byte 0        ; 1 if Space was down last frame (edge detect)
chargeTimer !byte 0        ; frames Space held; >=CHARGE_THRESHOLD -> beam on release
bulColor    !byte 0        ; scratch: color for spawn_player_bullet
bulExpand   !byte 0        ; scratch: expand flag for spawn_player_bullet
; sort/build scratch
sortKey  !byte 0
sortJ    !byte 0
tmpSlot  !byte 0
schBack  !byte 0
schBackBase !byte 0
bsBase   !byte 0
ss_x     !byte 1
; bit masks indexed by hardware sprite number 0..7
msbset   !byte $01,$02,$04,$08,$10,$20,$40,$80
msbclr   !byte $fe,$fd,$fb,$f7,$ef,$df,$bf,$7f
playerState !byte 0        ; 0 alive, 1 exploding, 2 invulnerable
playerTimer !byte 0
lives       !byte 3
flashTimer  !byte 0        ; border flash countdown (game over)
score       !byte 0,0,0   ; 3-byte BCD, low byte first (6 digits)
killCount   !byte 0
bossState   !byte 0
bossHP      !byte 0
bossXlo     !byte 0
bossXhi     !byte 0
bossY       !byte 0
bossYCenter !byte 0
bossPhase   !byte 0
bossFireTimer !byte 0
bossFlash   !byte 0
bossDeathTimer !byte 0
bossOffY    !byte $e8,$f4,$00,$0c,$18   ; -24,-12,0,12,24 (signed)
sfxTimer    !fill 3,0          ; frames remaining per voice (0 = idle)
sfxFreqLo   !fill 3,0
sfxFreqHi   !fill 3,0
sfxSweepLo  !fill 3,0          ; signed 16-bit per-frame freq delta
sfxSweepHi  !fill 3,0
sfxRelease  !fill 3,0          ; control-reg value with gate cleared (note-off)
sidbase_lo  !byte $00,$07,$0e  ; SID voice base low bytes (high byte $d4)
