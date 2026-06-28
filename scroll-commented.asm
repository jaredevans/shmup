; =====================================================================
;  R-TYPE-STYLE SHMUP  -  STAGE 2: SCROLL + PLAYER SHIP (IJKL) + BULLET (SPACE)
;  Target: Commodore 64 (PAL)   Assembler: ACME
;  Build:  acme -f cbm -o scroll.prg scroll.asm
;  Run:    x64sc scroll.prg    (auto-runs via BASIC stub, or SYS 2064)
; =====================================================================

VIC      = $d000                ; base address of VIC-II register block
RASTER   = $d012                ; VIC-II raster counter / IRQ compare register
SCROLY   = $d011                ; vertical scroll, screen height, bitmap/MCM mode
SCROLX   = $d016                ; horizontal scroll (bits0-2), 38/40-col (bit3), MCM (bit4)
VICMEM   = $d018                ; screen RAM base (top nibble) + charset base (bits1-3)
VICIRQ   = $d019                ; VIC IRQ status latch; write to acknowledge
IRQMASK  = $d01a                ; VIC IRQ enable mask (bit0 = raster IRQ enable)
BORDER   = $d020                ; border color register
BGCOL0   = $d021                ; background color 0 (main background in MCM)
BGCOL1   = $d022                ; background color 1 (multicolor bit-pair 10)
BGCOL2   = $d023                ; background color 2 (multicolor bit-pair 11)

CIA1_ICR = $dc0d                ; CIA 1 interrupt control register; bit7=set/clr, bit0=timer A
CIA2_ICR = $dd0d                ; CIA 2 interrupt control register; same layout as CIA1_ICR

IRQVEC   = $0314                ; KERNAL IRQ vector (lo byte); +1 = hi byte

MUX_LEAD = 16               ; raster lead lines before sprite Y. Must be big enough to PROGRAM a
                            ; whole band of same-line sprites before the raster reaches them: the
                            ; mux IRQ costs ~100+ cycles (a couple of scanlines) per sprite, so a
                            ; band of ~7 needs a dozen-plus lines of lead — set to 16 with margin.
                            ; Measured: only 3 of 7 same-line sprites appeared at LEAD=3, all 7 at
                            ; 16 — the late ones were missing their turn-on line, not short of slots.
SPRSPAN  = 37               ; min Y gap to safely REUSE a hardware sprite = 21 (sprite height) +
                            ; MUX_LEAD. Below this gap the old sprite is still being drawn when the
                            ; mux wants to reprogram its hardware slot. Used by build_schedule's guard.

ENEMY_SPEED   = 2               ; pixels per frame enemies move left
SPAWN_INTERVAL = 45             ; frames between enemy wave spawns
EXPLODE_FRAMES = 8              ; how many frames an enemy explosion lasts
ENEMY_COLOR   = 2          ; red
EXPLODE_COLOR = 1          ; white
HITW          = 12         ; hit box half-width (pixels)
HITH          = 12         ; hit box half-height (pixels)
ENEMY_FIRE_INTERVAL = 30        ; frames between enemy bullet shots
EBULLET_SPEED = 3               ; enemy bullet horizontal speed (pixels/frame, leftward)
EBULLET_COLOR = 3          ; cyan

D016_HUD      = $18        ; MCM=1, 40-col, fine=0  (HUD rows)
D016_PLAY_BASE = $10       ; MCM=1, 38-col          (| fine_x for playfield)
SPLIT_LINE    = 65         ; raster line of the row1/row2 split (tunable)
HUD_COLOR     = 1          ; HUD band color (white)
DIGIT_BASE    = 16         ; screen codes for digit 0..9 (16-25)
SCORE_PER_KILL = $10       ; 10 points per kill (BCD)

BOSS_KILL_THRESHOLD = 5         ; kills required before boss appears
BOSS_HP       = 5               ; boss hit points (5 hits to destroy)
BOSS_COLOR    = 4          ; purple
BOSS_ENTER_SPEED = 2            ; pixels/frame boss moves onto screen during ENTER state
BOSS_FIRE_INTERVAL = 50         ; frames between boss bullet volleys
BOSS_DEATH_FRAMES = 30          ; frames the boss death animation runs
BOSS_FLASH_FRAMES = 4           ; frames per color flash during boss death
BS_INACTIVE = 0                 ; bossState: boss not yet spawned
BS_ENTER    = 1                 ; bossState: boss sliding onto screen from right
BS_FIGHT    = 2                 ; bossState: boss active, bobbing and firing
BS_DYING    = 3                 ; bossState: boss hit-kill animation playing

PLAYER_LIVES    = 3             ; starting lives
PEXPLODE_FRAMES = 24            ; frames for player explosion animation
INVULN_FRAMES   = 100           ; frames of invulnerability after respawn
PHITW           = 14            ; player hit box half-width (pixels)
PHITH           = 16            ; player hit box half-height (pixels)
PS_ALIVE        = 0             ; playerState: ship active, accepting input
PS_EXPLODE      = 1             ; playerState: playing death explosion
PS_INVULN       = 2             ; playerState: respawned, blinking, can't be hit

; ---- two screen buffers (both inside VIC bank 0) -----------------------
BUF_A    = $0400                ; front screen buffer A (VIC default screen page)
BUF_B    = $3800            ; moved from $0c00: program code+tables grew past $0c00 and
                            ; clobbered the row-address tables that lived inside the old BUF_B
COLORRAM = $d800                ; color RAM (fixed at $D800, cannot be relocated by VIC)
CHARSET  = $2000                ; custom charset base address (within VIC bank 0)

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
        !byte $0c,$08,$0a,$00,$9e,$32,$30,$36,$34,$00,$00,$00 ; BASIC line: 10 SYS 2064 + end-of-program sentinel

* = $0810
start
        sei                     ; disable maskable IRQs while setting up interrupt system
        lda #$7f
        sta CIA1_ICR            ; write $7F to CIA1 ICR: clears all CIA1 interrupt enables (bit7=0 means clear)
        sta CIA2_ICR            ; write $7F to CIA2 ICR: clears all CIA2 interrupt enables (prevents NMI/IRQ from CIAs)
        lda CIA1_ICR            ; read CIA1 ICR to acknowledge and drain any pending CIA1 interrupt flags
        lda CIA2_ICR            ; read CIA2 ICR to acknowledge and drain any pending CIA2 interrupt flags

        jsr build_charset       ; construct custom multicolor charset at $2000 (digits, letters, tile glyphs)
        lda #0
        sta score               ; zero score byte 0 (BCD low)
        sta score+1             ; zero score byte 1 (BCD mid)
        sta score+2             ; zero score byte 2 (BCD high)
        lda #0
        sta bossState           ; set boss state to BS_INACTIVE (0): no boss on screen
        sta killCount           ; reset kill counter used to trigger boss spawn
        jsr set_colors          ; set VIC background/border colors and color RAM for playfield
        jsr sid_init            ; initialize SID chip: silence all voices, set volume

        ; --- initial state: A is front, fill A from first 40 map columns,
        ;     and copy A->B so both buffers start identical -------------
        lda #1
        sta front_is_a          ; flag buffer A as the current front (visible) buffer

        jsr fill_front_from_map     ; fills BUF_A and positions zp_map @ col40
        jsr copy_a_to_b             ; B starts identical to A
        jsr init_hud_bar            ; fill rows 0-1 of both buffers with HUD bar
        jsr init_sprites            ; sprite pointers (both buffers), regs, art
        lda #30
        sta spawnTimer          ; first enemy spawns soon
        lda #0
        sta spawnIndex          ; start at wave entry 0
        lda #ENEMY_FIRE_INTERVAL
        sta enemyFireTimer      ; prime enemy fire countdown
        lda #6
        sta enemyFireIndex      ; first enemy fire check starts at virtual slot 6 (enemy slots)

        lda #7
        sta fine_x              ; start fine scroll at 7 (rightmost pixel; will count down to 0)
        lda #2
        sta build_row           ; start back-buffer builds at row 2 (rows 0-1 are HUD, never rebuilt by scroll)

        ; --- VIC setup: multicolor, 38-col, show buffer A ---------------
        lda #D18_A
        sta VICMEM              ; point VIC screen to $0400 (BUF_A) and charset to $2000

        lda #%00011000              ; MCM=1, 38col=0(set later), xscroll=0
        ora #7                      ; fine = 7
        sta SCROLX              ; SCROLX: MCM on, fine X-scroll = 7 (initial fine offset)
        ; switch to 38-column to hide seam (clear bit3)
        lda SCROLX
        and #%11110111          ; clear bit3 to select 38-column mode (hides left/right border seam during scroll)
        sta SCROLX              ; write back: MCM=1, 38-col, fine=7

        lda #%00011011
        sta SCROLY              ; SCROLY: screen on, 25 rows, bitmap=0, ECM=0, vert scroll=3
        and #$7f
        sta SCROLY              ; clear bit7 of SCROLY (ensures raster IRQ compare uses $D012 only, not bit8)

        lda #0
        sta BORDER              ; black border
        sta BGCOL0              ; black background color 0 (space/starfield background in MCM)

        ; --- raster IRQ at line 250 ------------------------------------
        lda #<scroll_irq
        sta IRQVEC              ; set IRQ vector lo byte to scroll_irq (fires at raster line 250, bottom of screen)
        lda #>scroll_irq
        sta IRQVEC+1            ; set IRQ vector hi byte to scroll_irq
        lda #250
        sta RASTER              ; set raster compare to line 250 (below visible area, safe for per-frame work)
        lda #%00000001
        sta IRQMASK             ; enable raster IRQ in VIC (bit0); disables all other VIC IRQ sources
        lda VICIRQ
        sta VICIRQ              ; acknowledge any pending VIC IRQ by writing latch back to itself (clears flags)
        cli                     ; enable IRQs: raster IRQ chain now active

main_loop
        lda frame_ready
        beq main_loop               ; wait for next frame
        lda #0
        sta frame_ready             ; consume it
        jsr player_update           ; read joystick/keyboard, move player ship, handle fire, update playerState
        jsr spawn_enemies           ; decrement spawnTimer; when zero, activate next wave entry and reset timer
        jsr enemy_fire              ; decrement enemyFireTimer; when zero, pick an active enemy and spawn bullet
        jsr boss_update             ; run boss state machine: ENTER slide-in, FIGHT bob+fire, DYING flash+remove
        jsr update_enemies          ; move active enemies left by ENEMY_SPEED; deactivate when off screen
        jsr update_enemy_bullets    ; move active enemy bullets left by EBULLET_SPEED; deactivate when off screen
        jsr update_bullets          ; move active player bullets right; deactivate when off screen
        jsr check_hits              ; test player bullets vs enemies/boss; score kills, trigger explosions
        jsr check_player_hit        ; test enemy bullets + enemy bodies vs player; trigger PS_EXPLODE if hit
        jsr sound_update            ; advance all active SID effects one frame (frequency sweep, envelope)
        jsr draw_hud                ; render score (BCD->digits) and lives count into HUD rows of both buffers
        jsr sort_sprites            ; sort virtual sprite array by Y for multiplexer; assign hardware sprite slots
        jsr build_schedule          ; populate mux IRQ trigger table from sorted virtual sprites
        jmp main_loop               ; loop forever; frame pacing is IRQ-driven via frame_ready flag

; =====================================================================
;  RASTER IRQ CHAIN
;  scroll_irq: bottom-of-frame work (scroll + frame flag) + arm mux chain
;  mux_irq:    programs hw sprites 1-7 round-robin, chains on raster
; =====================================================================

; --- bottom-of-frame IRQ: scroll work, set HUD $D016, arm split_irq ---
scroll_irq
        lda VICIRQ              ; read $D019: VIC-II IRQ status latch (which IRQ fired)
        sta VICIRQ              ; writing latch back clears it — acknowledges raster IRQ
        jsr scroll_step         ; advance fine-scroll counter; every 8 steps coarse-flip buffers
        inc frame_ready         ; tell main loop a new frame has been processed (poll flag)
        ; HUD region (top of next frame): 40-col, no fine scroll
        lda #D016_HUD           ; $D016 value for HUD rows: 40-column mode, fine-scroll bits = 0
        sta SCROLX              ; write to VIC-II $D016 (SCROLX): sets HUD display mode
        ; arm the split IRQ at the HUD/playfield boundary
        lda #<split_irq         ; low byte of split_irq handler address
        sta IRQVEC              ; store to KERNAL IRQ vector low byte ($0314)
        lda #>split_irq         ; high byte of split_irq handler address
        sta IRQVEC+1            ; store to KERNAL IRQ vector high byte ($0315)
        lda #SPLIT_LINE         ; scanline number where HUD ends and playfield begins
        sta RASTER              ; write to $D012: VIC-II fires next raster IRQ here
        pla                     ; restore Y (pushed as A by IRQ entry; pulled in reverse)
        tay
        pla                     ; restore X
        tax
        pla                     ; restore A
        rti                     ; return from interrupt, re-enable interrupt flag

; --- split IRQ: switch to playfield scroll mode, then arm the mux chain ---
split_irq
        lda VICIRQ              ; read $D019 to acknowledge the raster IRQ
        sta VICIRQ              ; clear latch by writing it back
        ; playfield region below the split: 38-col + fine scroll
        lda #D016_PLAY_BASE     ; base $D016 for scrolling playfield: 38-column mode + MCM bit
        ora fine_x              ; OR in fine horizontal scroll offset (0-7 pixels, bits 0-2)
        sta SCROLX              ; write combined value to $D016 — activates scrolling mode below HUD
        ; arm next: mux chain (if sprites) else scroll_irq@250
        jsr park_mux_sprites    ; move hw sprites 1-7 off-screen before mux reprograms them
        lda #1                  ; start muxing from hw sprite 1 (sprite 0 = player ship, always on)
        sta muxHW               ; muxHW: which hardware sprite slot (1-7) is being programmed next
        ldx #0                  ; default schedule start index: 0 (front bank starts at 0)
        lda schFront            ; schFront: which sprite schedule bank is the live "front" bank
        beq sp_base0            ; if schFront=0, index 0 is correct; skip adjustment
        ldx #15                 ; schFront=1: second bank starts at index 15 in the schedule arrays
sp_base0
        stx muxIdx              ; muxIdx = first schedule entry to program this frame
        ldy schFront            ; index into schCount table by front bank (0 or 1)
        txa                     ; A = start index
        clc
        adc schCount,y          ; add number of active virtual sprites in this bank
        sta muxEnd              ; muxEnd = one-past-last valid schedule entry (end sentinel)
        lda muxEnd              ; re-read end sentinel
        cmp muxIdx              ; equal means count was zero — no virtual sprites this frame
        beq sp_nosprites        ; skip mux entirely if no sprites to display
        lda #<mux_irq           ; low byte of mux_irq handler address
        sta IRQVEC              ; redirect IRQ vector to mux_irq (low byte)
        lda #>mux_irq           ; high byte of mux_irq handler address
        sta IRQVEC+1            ; redirect IRQ vector to mux_irq (high byte)
        ldx muxIdx              ; X = first schedule entry index
        lda schY,x              ; load Y screen position of the first virtual sprite
        sec
        sbc #MUX_LEAD           ; subtract lead time — fire IRQ a few lines BEFORE sprite Y
        cmp #SPLIT_LINE+1       ; is that line still BELOW the HUD raster split?
        bcs sp_armok            ; yes (>= split+1): the computed line is safe, use it
        lda #SPLIT_LINE+1       ; no: a big MUX_LEAD pushed it at/above the split. Clamp to just
                               ; below the split — scheduling an already-passed line would stall the
                               ; IRQ chain for a whole frame. The mux burst still catches up via its
                               ; own behind-the-raster check once it starts firing.
sp_armok
        sta RASTER              ; arm raster IRQ to fire MUX_LEAD lines above first sprite (clamped)
        jmp sp_exit             ; done — skip the no-sprites fallback path
sp_nosprites
        lda #<scroll_irq        ; no sprites this frame: skip mux chain entirely
        sta IRQVEC              ; restore IRQ vector low byte directly to scroll_irq
        lda #>scroll_irq        ; high byte of scroll_irq address
        sta IRQVEC+1            ; restore IRQ vector high byte to scroll_irq
        lda #250                ; re-arm at raster line 250 (bottom-of-frame position)
        sta RASTER              ; write next IRQ trigger line to $D012
sp_exit
        pla                     ; restore Y
        tay
        pla                     ; restore X
        tax
        pla                     ; restore A
        rti                     ; return from IRQ

; --- multiplex IRQ: program next hw sprite(s), chain to next raster line ---
; =====================================================================
;  SPRITE MULTIPLEXER — WHY IT EXISTS AND HOW IT WORKS
;
;  HARDWARE LIMIT: The VIC-II chip has exactly 8 hardware sprites
;  (numbered 0-7). On each horizontal scanline the chip can only fetch
;  and draw those 8 sprites — there is no way to display more than 8
;  sprites visible at the same time on the screen.
;
;  THE MULTIPLEXING TRICK: Because the raster beam draws the screen
;  from top to bottom, a hardware sprite that has finished being drawn
;  (its Y region is past) can be REPROGRAMMED on-the-fly: new X, Y,
;  shape pointer, and color are written mid-frame so the same hardware
;  slot appears again lower on the screen as a completely different
;  virtual sprite. A raster IRQ fires just before the beam reaches the
;  next virtual sprite's Y, and the IRQ handler reprograms one hardware
;  sprite for the next virtual sprite. This lets 7 mux slots (hw 1-7;
;  hw 0 is the player ship and never changes) service up to 15 virtual
;  sprite slots:
;    virtual 0-5   = player bullets
;    virtual 6-10  = enemies (or the 5 boss-segment pieces)
;    virtual 11-14 = enemy / boss bullets
;
;  WHY SPRITES FLICKER OR VANISH WHEN TOO MANY SHARE A SCANLINE:
;  The multiplexer works by sorting virtual sprites by Y and assigning
;  a hardware slot to each in raster order. But if two virtual sprites
;  have nearly the same Y coordinate, they need to be visible on the
;  same scanlines simultaneously — and the same hardware slot CANNOT
;  be in two places at once. Worse, if more than 7 virtual sprites
;  (the number of mux-able hw slots) overlap on the same group of
;  scanlines, there are simply not enough hardware slots to go around.
;  The sprites that cannot be assigned a slot are skipped that frame:
;  they do not appear, so they flicker or vanish entirely. This is a
;  fundamental VIC-II hardware constraint, not a software bug. The
;  mux manages it as well as possible by processing sprites strictly
;  in Y order; whichever virtual sprites are bunched together lose out.
; =====================================================================
mux_irq
        lda VICIRQ              ; read $D019: acknowledge the raster IRQ
        sta VICIRQ              ; clear latch — must do this or IRQ re-fires immediately
mux_loop
        ldx muxIdx              ; X = current schedule index (next virtual sprite to program)
        cpx muxEnd              ; compare to end sentinel — are all virtual sprites done?
        bcs mux_done            ; if muxIdx >= muxEnd, finished all sprites this frame
        ; program hw sprite muxHW from schedule entry x
        lda muxHW               ; A = current hardware sprite number (1-7)
        asl                     ; multiply by 2 (each hw sprite has 2 position regs: X at even, Y at odd)
        tay                     ; y = 2*hw (X/Y register index)
        lda schXlo,x            ; low 8 bits of virtual sprite's screen X position
        sta $d000,y             ; write to VIC-II sprite X register ($D000 + 2*hw)
        lda schY,x              ; virtual sprite's screen Y position
        sta $d001,y             ; write to VIC-II sprite Y register ($D001 + 2*hw)
        ldy muxHW               ; Y = hw sprite number (for bit-table and color indexing)
        lda schXhi,x            ; X position bit 9 (MSB) — set when sprite is right half of screen
        beq mx_clr              ; if zero, X fits in 8 bits — clear the MSB bit in $D010
        lda $d010               ; read current sprite X MSB register ($D010, one bit per sprite)
        ora msbset,y            ; RMW: set bit for this hw sprite
        sta $d010               ; write back: sprite can now reach X positions 256-343
        jmp mx_col              ; skip the clear path
mx_clr
        lda $d010               ; read $D010 sprite X MSB register
        and msbclr,y            ; RMW: clear bit for this hw sprite
        sta $d010               ; write back: sprite X is 0-255 (left half of screen)
mx_col
        ldy muxHW               ; Y = hw sprite number (index into $D027-$D02E color regs)
        lda schColor,x          ; virtual sprite's color value
        sta $d027,y             ; write to VIC-II sprite color register ($D027 + hw)
        ; advance schedule index + round-robin hw 1..7
        inc muxIdx              ; move to next virtual sprite in the schedule
        ldy muxHW               ; Y = current hw sprite number
        iny                     ; advance to next hw sprite slot
        cpy #8                  ; past slot 7? (slots 1-7 are the mux range)
        bne mx_hwok             ; no — still in range
        ldy #1                  ; yes — wrap back to slot 1 (slot 0 is the player ship, skip it)
mx_hwok
        sty muxHW               ; save updated hw sprite number for next iteration
        ; decide next IRQ line or loop
        ldx muxIdx              ; X = next schedule index
        cpx muxEnd              ; check if we've finished all virtual sprites
        bcs mux_done            ; if done, hand off to scroll_irq
        lda schY,x              ; Y position of the next virtual sprite to program
        sec
        sbc #MUX_LEAD           ; subtract lead time — IRQ must fire before the sprite's scanline
        cmp RASTER              ; desired IRQ line vs. current raster position ($D012 read)
        bcc mux_loop            ; desired < current raster — beam already past it, program now
        sta RASTER              ; arm next IRQ at (next sprite Y - MUX_LEAD)
        cmp RASTER              ; re-read $D012 to check for race: did beam pass while storing?
        bcc mux_loop            ; if still behind — loop immediately rather than waiting for IRQ
        jmp mux_exit            ; IRQ armed correctly — exit handler and wait for next raster IRQ
mux_done
        ; last sprite done -> hand off to scroll_irq at line 250
        lda #<scroll_irq        ; low byte of scroll_irq address
        sta IRQVEC              ; restore IRQ vector low byte to scroll_irq
        lda #>scroll_irq        ; high byte of scroll_irq address
        sta IRQVEC+1            ; restore IRQ vector high byte to scroll_irq
        lda #250                ; raster line 250 = bottom-of-frame, where scroll work happens
        sta RASTER              ; arm scroll_irq to fire at line 250 next frame
mux_exit
        pla                     ; restore Y from stack
        tay
        pla                     ; restore X from stack
        tax
        pla                     ; restore A from stack
        rti                     ; return from interrupt

; --- init_hud_bar: fill rows 0-1 of BOTH buffers with char 2 + HUD color ---
; (temporary HUD marker; Task 2 replaces with score/lives digits)
init_hud_bar
        ldx #0                  ; X = byte offset into screen buffer, start at 0
ihb_loop
        cpx #80                 ; 2 rows x 40 cols = 80 cells
        bcs ihb_done            ; if X >= 80, all HUD cells written
        lda #0                  ; blank tile
        sta BUF_A,x             ; clear cell in front screen buffer (BUF_A=$0400)
        sta BUF_B,x             ; clear same cell in back screen buffer (BUF_B=$3800)
        lda #HUD_COLOR          ; HUD color attribute value
        sta COLORRAM,x          ; write color to color RAM ($D800+X); fixed at $D800 regardless of buffer
        inx                     ; advance to next cell
        jmp ihb_loop            ; loop until all 80 HUD cells initialized
ihb_done
        ; --- static labels: "Score: " row 0 col 0, "Ships left: " row 1 col 0 ---
        ldx #0                  ; X = character index within label
ihb_sc
        cpx #7                  ; "Score: " is 7 characters (cols 0-6)
        bcs ihb_sc_done         ; if X >= 7, all Score label chars written
        lda label_score,x       ; load next character code from "Score: " label data
        sta BUF_A,x             ; write to front buffer row 0
        sta BUF_B,x             ; write to back buffer row 0 (kept in sync)
        inx                     ; next character
        jmp ihb_sc              ; loop until all 7 chars written
ihb_sc_done
        ldx #0                  ; X = character index within ships label
ihb_sh
        cpx #12                 ; "Ships left: " is 12 characters (cols 0-11)
        bcs ihb_sh_done         ; if X >= 12, all Ships label chars written
        lda label_ships,x       ; load next character from "Ships left: " label data
        sta BUF_A+40,x          ; row 1
        sta BUF_B+40,x          ; same char to back buffer row 1 (offset 40 = second row)
        inx                     ; next character
        jmp ihb_sh              ; loop until all 12 chars written
ihb_sh_done
        rts                     ; return — HUD rows initialized in both buffers

; ---------------------------------------------------------------------
; draw_hud: write 6 score digits (cols 0..5) + lives digit (col 38) to
; row 0 of both screen buffers. BCD score; score+2 = leftmost pair.
; ---------------------------------------------------------------------
draw_hud
        ; "Score: " is at row0 cols 0-6; score digits go at cols 7-12.
        ; high pair (score+2) -> cols 7,8
        lda score+2             ; load most-significant BCD byte of score (digits 5-4)
        jsr dh_split            ; A hi-nibble -> dhHi (code), lo-nibble -> dhLo (code)
        lda dhHi                ; char code for score digit 5 (leftmost)
        sta BUF_A+7             ; write to front buffer row 0 col 7
        sta BUF_B+7             ; write same char to back buffer row 0 col 7
        lda dhLo                ; char code for score digit 4
        sta BUF_A+8             ; write to front buffer row 0 col 8
        sta BUF_B+8             ; write same char to back buffer row 0 col 8
        ; mid pair (score+1) -> cols 9,10
        lda score+1             ; load middle BCD byte of score (digits 3-2)
        jsr dh_split            ; split into two digit char codes
        lda dhHi                ; char code for score digit 3
        sta BUF_A+9             ; write to front buffer row 0 col 9
        sta BUF_B+9             ; write same to back buffer
        lda dhLo                ; char code for score digit 2
        sta BUF_A+10            ; write to front buffer row 0 col 10
        sta BUF_B+10            ; write same to back buffer
        ; low pair (score+0) -> cols 11,12
        lda score+0             ; load least-significant BCD byte (digits 1-0)
        jsr dh_split            ; split into two digit char codes
        lda dhHi                ; char code for score digit 1
        sta BUF_A+11            ; write to front buffer row 0 col 11
        sta BUF_B+11            ; write same to back buffer
        lda dhLo                ; char code for score digit 0 (rightmost)
        sta BUF_A+12            ; write to front buffer row 0 col 12
        sta BUF_B+12            ; write same to back buffer
        ; "Ships left: " is at row1 cols 0-11; lives digit at row1 col 12 (offset 52)
        lda lives               ; current lives count (0-9)
        clc
        adc #DIGIT_BASE         ; convert raw count to custom charset digit char code
        sta BUF_A+52            ; write to front buffer: row 1 col 12 (40+12=52)
        sta BUF_B+52            ; write same to back buffer row 1 col 12
        rts                     ; return — both buffers now show updated score and lives

; split BCD byte A into two digit char codes: dhHi (high nibble), dhLo (low nibble)
dh_split
        pha                     ; save original BCD byte (need it twice: hi nibble then lo nibble)
        lsr                     ; shift right 1
        lsr                     ; shift right 2
        lsr                     ; shift right 3
        lsr                     ; shift right 4: high nibble is now in bits 0-3
        clc
        adc #DIGIT_BASE         ; add charset base offset to turn nibble (0-9) into digit char code
        sta dhHi                ; store high-nibble digit char code
        pla                     ; restore original BCD byte
        and #$0f                ; mask off upper nibble — keep only low nibble (bits 0-3)
        clc
        adc #DIGIT_BASE         ; convert low nibble to digit char code
        sta dhLo                ; store low-nibble digit char code
        rts                     ; return: dhHi = tens digit code, dhLo = units digit code
dhHi !byte 0                    ; temp storage: char code for high (tens) BCD digit
dhLo !byte 0                    ; temp storage: char code for low (units) BCD digit
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
        lda flashTimer          ; load border-flash countdown (set to 20 by game_over, 0 = no flash)
        beq pu_disp             ; zero = no flash active, skip straight to state dispatch
        dec flashTimer          ; decrement flash timer each frame
        bne pu_disp             ; still counting down, leave border color as-is
        lda #0                  ; timer just hit zero: prepare black (color 0)
        sta BORDER              ; $D020: restore border to black when flash expires
pu_disp
        lda playerState         ; 0=PS_ALIVE, 1=PS_EXPLODE, 2=PS_INVULN
        bne pu_not_alive        ; nonzero = not fully alive, branch away
        jmp pu_normal_play      ; ALIVE: normal play (ends in rts)
pu_not_alive
        cmp #PS_INVULN          ; test for invulnerability state (value 2)
        beq pu_invuln           ; branch to invuln handler if so
        ; PS_EXPLODE: frozen, blink, count down
        lda #$ff                ; $FF = all bits set (no key appears pressed)
        sta keyrow7             ; freeze firing during explosion (update_bullets reads keyrow7)
        jsr pu_blink            ; toggle sprite 0 visibility for explosion blink effect
        dec playerTimer         ; count down explosion duration (set to PEXPLODE_FRAMES on hit)
        beq pu_explode_end      ; reached zero: explosion animation finished
        rts                     ; still exploding, nothing more to do this frame
pu_explode_end
        lda lives               ; check remaining lives
        beq pu_gameover         ; zero lives -> trigger game over sequence
        jsr player_respawn      ; lives remain: respawn at start position as invulnerable
        rts
pu_gameover
        jsr game_over           ; reset all game state and flash border red
        rts
pu_invuln
        jsr pu_normal_play      ; can move/fire while invulnerable
        jsr pu_blink            ; blink sprite 0 to signal invulnerability to player
        dec playerTimer         ; count down invulnerability duration (set to INVULN_FRAMES on respawn)
        bne pu_inv_ret          ; still counting, return
        lda #PS_ALIVE           ; timer expired: transition to fully ALIVE state
        sta playerState         ; write new state (0 = PS_ALIVE)
        lda SPENA               ; $D015: sprite enable register (1 bit per hardware sprite)
        ora #%00000001          ; ensure bit 0 (sprite 0 = player ship) is set
        sta SPENA               ; guarantee player sprite is visible at end of invulnerability
pu_inv_ret
        rts

pu_normal_play
        ; --- scan keyboard matrix rows ---
        lda #$ef                ; %11101111: assert row 4 (PA4 low) — contains I, J, K keys
        sta $dc00               ; CIA1 port A ($DC00): select keyboard matrix row for reading
        lda $dc01               ; CIA1 port B ($DC01): read column bits for selected row (0=pressed)
        sta keyrow4             ; cache row 4 result: bit1=I(up), bit2=J(left), bit5=K(down)
        lda #$df                ; %11011111: assert row 5 (PA5 low) — contains L key
        sta $dc00               ; CIA1 port A: select keyboard matrix row 5
        lda $dc01               ; read column bits for row 5
        sta keyrow5             ; cache row 5 result: bit2=L(right)
        lda #$7f                ; %01111111: assert row 7 (PA7 low) — contains space bar
        sta $dc00               ; CIA1 port A: select keyboard matrix row 7
        lda $dc01               ; read column bits for row 7
        sta keyrow7             ; cache row 7 result: bit4=space(fire); also read by update_bullets

        ; --- vertical: I (bit1)=up, K (bit5)=down ---
        lda keyrow4             ; reload row 4 key state
        and #%00000010          ; isolate bit 1 = I key
        bne pu_not_up           ; bit set = key NOT pressed (C64 matrix: 0=pressed, 1=released)
        lda player_y            ; I held: load current Y pixel position
        sec                     ; set carry for subtraction
        sbc #2                  ; move up 2 pixels per frame
        sta player_y            ; store updated Y (clamped below by clamp_player)
pu_not_up
        lda keyrow4             ; reload row 4 key state
        and #%00100000          ; isolate bit 5 = K key
        bne pu_not_down         ; bit set = K NOT pressed
        lda player_y            ; K held: load current Y
        clc                     ; clear carry for addition
        adc #2                  ; move down 2 pixels per frame
        sta player_y            ; store updated Y
pu_not_down

        ; --- horizontal: J (row4 bit2)=left, L (row5 bit2)=right ---
        lda keyrow4             ; reload row 4 key state
        and #%00000100          ; isolate bit 2 = J key
        bne pu_not_left         ; bit set = J NOT pressed
        lda player_x            ; J held: load X low byte (player uses 9-bit X: hi:lo)
        sec                     ; set carry for 16-bit subtraction
        sbc #2                  ; subtract 2 from low byte: move left 2 pixels
        sta player_x            ; store updated X low byte
        lda player_x_hi         ; load X high bit (9th bit, 0 or 1)
        sbc #0                  ; propagate borrow from low byte subtraction into high bit
        sta player_x_hi         ; store updated X high bit (handles crossing 256 boundary)
pu_not_left
        lda keyrow5             ; load row 5 key state
        and #%00000100          ; isolate bit 2 = L key
        bne pu_not_right        ; bit set = L NOT pressed
        lda player_x            ; L held: load X low byte
        clc                     ; clear carry for 16-bit addition
        adc #2                  ; add 2 to low byte: move right 2 pixels
        sta player_x            ; store updated X low byte
        lda player_x_hi         ; load X high bit
        adc #0                  ; propagate carry into high bit (9-bit X: handles crossing 256)
        sta player_x_hi         ; store updated X high bit
pu_not_right

        jsr clamp_player        ; enforce screen boundaries: X in [24,320], Y in [70,229]
        jsr write_player_sprite ; push player_x/player_y to VIC-II sprite 0 hardware registers
        rts

; blink sprite 0 by toggling SPENA bit 0 on (playerTimer & 4)
pu_blink
        lda playerTimer         ; load current state countdown (explosion or invuln timer)
        and #%00000100          ; test bit 2: changes every 4 frames -> ~8 Hz blink at 50fps
        beq pb_show             ; bit clear = even phase: show the sprite
        lda SPENA               ; odd phase: load sprite enable register ($D015)
        and #%11111110          ; clear bit 0: disable hardware sprite 0 (player ship)
        sta SPENA               ; write back: sprite 0 hidden this frame
        rts
pb_show
        lda SPENA               ; even phase: load sprite enable register
        ora #%00000001          ; set bit 0: enable hardware sprite 0 (player ship)
        sta SPENA               ; write back: sprite 0 visible this frame
        rts

; respawn player at start, become invulnerable
player_respawn
        lda #60                 ; starting X low byte = 60 (left quarter of screen)
        sta player_x            ; set player X lo (9-bit: 60 < 256, so hi=0)
        lda #0                  ; high bit = 0 (X < 256, no MSB needed in $D010)
        sta player_x_hi         ; clear 9th bit of player X
        lda #120                ; starting Y = 120 (vertically centred in play area)
        sta player_y            ; set player Y coordinate
        lda #PS_INVULN          ; enter PS_INVULN state (value 2): can't be hit
        sta playerState         ; write new player state
        lda #INVULN_FRAMES      ; load invulnerability duration constant (frames)
        sta playerTimer         ; set countdown; pu_invuln decrements each frame
        lda SPENA               ; read sprite enable register ($D015)
        ora #%00000001          ; set bit 0: ensure player sprite is on after respawn
        sta SPENA               ; write back sprite enable
        jsr write_player_sprite ; immediately update hardware sprite 0 X/Y registers
        rts

; player_hit: only acts when ALIVE. lose a life, start explosion.
player_hit
        lda playerState         ; check current player state
        bne ph_ret              ; nonzero = already exploding or invulnerable: ignore hit
        dec lives               ; decrement remaining lives (will be tested on explosion end)
        lda #PS_EXPLODE         ; enter PS_EXPLODE state (value 1): frozen, blinking
        sta playerState         ; write explosion state
        lda #PEXPLODE_FRAMES    ; load explosion animation duration (frames)
        sta playerTimer         ; set countdown; player_update decrements each frame
        jsr sfx_hit             ; trigger hit/explosion sound effect via SID engine
ph_ret
        rts

; cph_overlap: bounding box between the PLAYER and virtual slot X.
; C set = overlap. Uses chDlo/chDhi scratch.
cph_overlap
        lda vsXlo,x             ; 16-bit dX = slotX - player_x
        sec                     ; set carry for 16-bit subtraction
        sbc player_x            ; low byte: vsXlo[x] - player_x lo
        sta chDlo               ; store delta X low byte in scratch
        lda vsXhi,x             ; load virtual sprite X high bit (9th bit)
        sbc player_x_hi         ; high byte: vsXhi[x] - player_x_hi - borrow
        sta chDhi               ; store delta X high byte (sign bit for 9-bit X)
        bpl co_xpos             ; result >= 0: dX is positive, skip negation
        lda #0                  ; dX is negative: negate to get |dX| (two's complement)
        sec                     ; set carry for subtraction from zero
        sbc chDlo               ; negate low byte: 0 - chDlo
        sta chDlo               ; store |dX| low byte
        lda #0                  ; reload zero for high byte negation
        sbc chDhi               ; negate high byte: 0 - chDhi - borrow
        sta chDhi               ; store |dX| high byte
co_xpos
        lda chDhi               ; check high byte of |dX|
        bne co_no               ; nonzero = |dX| >= 256: far outside hit box, no overlap
        lda chDlo               ; high byte is 0: check low byte of |dX|
        cmp #PHITW              ; compare against player hit-box half-width constant
        bcs co_no               ; |dX| >= PHITW: outside horizontal hit box, no overlap
        lda vsY,x               ; 8-bit |dY|: load virtual sprite Y
        sec                     ; set carry for subtraction
        sbc player_y            ; dY = vsY[x] - player_y
        bpl co_ypos             ; result >= 0: dY is already positive
        eor #$ff                ; dY negative: one's complement (flip all bits)
        clc                     ; clear carry for +1
        adc #1                  ; complete two's complement negation: |dY|
co_ypos
        cmp #PHITH              ; compare |dY| against player hit-box half-height constant
        bcs co_no               ; |dY| >= PHITH: outside vertical hit box, no overlap
        sec                     ; both axes overlap: set carry = hit detected
        rts
co_no
        clc                     ; no overlap: clear carry = miss
        rts

; ---------------------------------------------------------------------
; check_player_hit: only when ALIVE. Test player vs enemy bullets
; (11..14) and enemy bodies (6..10). On hit -> despawn/explode source,
; call player_hit, return (one hit/frame).
; ---------------------------------------------------------------------
check_player_hit
        lda playerState         ; check player state
        bne cph_ret             ; nonzero = not ALIVE (exploding/invuln): skip all checks
        ldx #11                 ; (a) enemy bullets: virtual slots 11-14
cph_eb
        cpx #15                 ; tested all four enemy bullet slots?
        bcs cph_enemies         ; yes: move on to enemy body checks
        lda vsActive,x          ; is bullet slot X active (1=alive, 0=empty)?
        beq cph_eb_next         ; inactive bullet: skip
        jsr cph_overlap         ; test bounding box: player vs this bullet (C set = hit)
        bcc cph_eb_next         ; no overlap: skip
        jsr ue_despawn          ; overlap: despawn the enemy bullet (remove from play)
        jsr player_hit          ; register the hit: lose a life, start explosion state
        rts                     ; one hit per frame maximum; return immediately
cph_eb_next
        inx                     ; advance to next bullet slot
        jmp cph_eb              ; continue bullet scan loop
cph_enemies
        ldx #6                  ; (b) enemy bodies: virtual slots 6-10 (or 5 boss pieces)
cph_en
        cpx #11                 ; tested all five enemy/boss slots?
        bcs cph_ret             ; yes: all checks done, no hit this frame
        lda vsActive,x          ; is enemy slot X active?
        beq cph_en_next         ; inactive: skip
        lda vsState,x           ; check enemy state: 0=alive, 1=exploding
        bne cph_en_next         ; already exploding: don't collide with explosion sprite
        jsr cph_overlap         ; test bounding box: player vs this enemy (C set = hit)
        bcc cph_en_next         ; no overlap: skip
        lda bossState           ; are we currently in a boss fight?
        beq cph_en_kamikaze     ; bossState==0 = no boss: treat as kamikaze enemy collision
        ; boss piece is solid: damage the player, leave the piece
        jsr player_hit          ; boss body hit: hurt player (boss piece stays on screen)
        rts
cph_en_kamikaze
        ; kamikaze: explode enemy + hit player
        lda #1                  ; vsState value 1 = exploding
        sta vsState,x           ; put enemy into explosion state (stops it from firing/moving)
        lda #EXPLODE_FRAMES     ; load explosion animation duration constant
        sta vsExplodeTimer,x    ; set explosion countdown for this enemy slot
        lda #1                  ; color 1 = white (bright explosion flash color)
        sta vsColor,x           ; set sprite color to white for explosion effect
        jsr player_hit          ; also hurt the player from the kamikaze collision
        rts
cph_en_next
        inx                     ; advance to next enemy slot
        jmp cph_en              ; continue enemy body scan loop
cph_ret
        rts

; ---------------------------------------------------------------------
; game_over: clear all actors, reset lives + timers, respawn player,
; flash border red.
; ---------------------------------------------------------------------
game_over
        ldx #0                  ; start clearing from virtual sprite slot 0
go_clear
        cpx #15                 ; cleared all 15 virtual sprite slots?
        bcs go_done             ; yes: done clearing
        lda #0                  ; prepare inactive flag
        sta vsActive,x          ; mark slot X as inactive (no sprite rendered)
        lda #255                ; Y=255: well below the visible screen (sprites 21px tall)
        sta vsY,x               ; park sprite Y off-screen so multiplexer won't schedule it
        inx                     ; advance to next slot
        jmp go_clear            ; loop over all 15 slots
go_done
        lda #PLAYER_LIVES       ; load default starting lives count constant
        sta lives               ; restore lives to default
        lda #0                  ; prepare zero for score clear
        sta score               ; clear score byte 0 (BCD ones/tens)
        sta score+1             ; clear score byte 1 (BCD hundreds/thousands)
        sta score+2             ; clear score byte 2 (BCD ten-thousands/hundred-thousands)
        lda #0                  ; prepare zero for state resets
        sta bossState           ; boss state = INACTIVE (0); no boss on restart
        sta killCount           ; reset enemy kill counter (controls wave/boss progression)
        lda #30                 ; 30-frame delay before first enemy spawn
        sta spawnTimer          ; set spawn countdown so player has a moment to orient
        lda #ENEMY_FIRE_INTERVAL ; load enemy fire rate constant
        sta enemyFireTimer      ; reset enemy fire timer to default interval
        lda #PS_ALIVE           ; player state = ALIVE (0)
        sta playerState         ; set player to alive (no explosion/invuln on restart)
        lda #60                 ; starting X low byte = 60
        sta player_x            ; set player X low byte
        lda #0                  ; high bit = 0 (X < 256)
        sta player_x_hi         ; clear player X high bit
        lda #120                ; starting Y = 120 (vertical centre)
        sta player_y            ; set player Y coordinate
        lda SPENA               ; read sprite enable register ($D015)
        ora #%00000001          ; ensure bit 0: player sprite (hardware sprite 0) is on
        sta SPENA               ; write back: player visible after game over reset
        jsr write_player_sprite ; push starting position to VIC-II sprite 0 registers
        lda #2                  ; red border flash; color 2 = red
        sta BORDER              ; $D020: set border color to red (game-over feedback)
        lda #20                 ; flash lasts 20 frames (~0.4 seconds at 50fps)
        sta flashTimer          ; set flash countdown; player_update clears border when done
        rts

; --- clamp player_x to [24,320], player_y to [70,229] ---
clamp_player
        ; Y low bound 70
        lda player_y            ; load current Y pixel position
        cmp #70                 ; compare against upper screen boundary (row below HUD)
        bcs cy_hi               ; Y >= 70: OK or too low, check upper limit
        lda #70                 ; Y < 70: would enter HUD area — clamp to minimum Y
        sta player_y            ; enforce minimum Y (keeps ship below the 2-row HUD)
        jmp cx                  ; skip upper-bound check, proceed to X clamp
cy_hi
        cmp #230                ; compare Y against lower boundary (just above HUD bar at bottom)
        bcc cx                  ; Y < 230: in range, proceed to X clamp
        lda #229                ; Y >= 230: clamp to maximum Y (229 = last safe row above HUD)
        sta player_y            ; enforce maximum Y
cx
        ; X low bound 24 (only possible when hi==0)
        lda player_x_hi         ; check high bit of 9-bit X position
        bne cx_high             ; hi != 0 means X >= 256: skip low-bound check, check hi-side
        lda player_x            ; hi==0: load X low byte
        cmp #24                 ; compare against left edge (24 pixels from left border)
        bcs cx_done             ; X >= 24: in range
        lda #24                 ; X < 24: clamp to left screen edge
        sta player_x            ; enforce minimum X
        jmp cx_done             ; done
cx_high
        ; hi>=1: clamp to max 320 ($140)
        lda player_x_hi         ; reload X high bit
        cmp #2                  ; hi >= 2 means X >= 512: way past right edge (320=$140)
        bcs cx_max              ; definitely over maximum, clamp now
        lda player_x            ; hi==1 (X in 256-511 range): check low byte vs $41
        cmp #$41                ; $140=320: if lo < $41 then X=$100+lo < 321, still in range
        bcc cx_done             ; lo < $41: X <= 320, OK
cx_max
        lda #$40                ; clamp lo byte to $40 (so X = $1_40 = 320)
        sta player_x            ; store clamped X low byte
        lda #1                  ; set hi byte to 1 (X = $140 = 320: right edge of play area)
        sta player_x_hi         ; store clamped X high bit
cx_done
        rts

; --- write player_x/player_y to sprite 0 registers ---
write_player_sprite
        lda player_x            ; load player X low byte (bits 0-7 of 9-bit X)
        sta $d000               ; $D000: VIC-II sprite 0 X position (low 8 bits)
        lda player_y            ; load player Y coordinate
        sta $d001               ; $D001: VIC-II sprite 0 Y position
        sei                     ; disable IRQs: read-modify-write of $D010 must be atomic
        lda $d010               ; $D010: MSB X bits for all 8 hardware sprites (1 bit each)
        and #%11111110          ; clear bit 0: sprite 0's 9th X bit (was possibly set)
        ldx player_x_hi         ; load player X high bit (0 or 1)
        beq wps_done            ; if zero (X < 256), leave bit 0 clear
        ora #%00000001          ; X >= 256: set bit 0 so sprite 0 appears past the 256px boundary
wps_done
        sta $d010               ; $D010: write updated MSB register (9-bit X for all sprites)
        cli                     ; re-enable IRQs now that $D010 update is complete
        rts

; park hardware sprites 1-7 below the screen (Y=$f8) so unused ones don't show stale data
park_mux_sprites
        lda #$f8                ; Y=$F8=248: below visible screen bottom (~230); sprite 21px tall so $F8 is safe
        sta $d003               ; $D003: hardware sprite 1 Y position — park off-screen
        sta $d005               ; $D005: hardware sprite 2 Y position — park off-screen
        sta $d007               ; $D007: hardware sprite 3 Y position — park off-screen
        sta $d009               ; $D009: hardware sprite 4 Y position — park off-screen
        sta $d00b               ; $D00B: hardware sprite 5 Y position — park off-screen
        sta $d00d               ; $D00D: hardware sprite 6 Y position — park off-screen
        sta $d00f               ; $D00F: hardware sprite 7 Y position — park off-screen
        rts

; =====================================================================
;  SORT_SPRITES: insertion-sort sortIdx[0..14] ascending by vsY[sortIdx[i]]
;  Outer index kept in ss_x (memory) to avoid X clobbering across inner loop.
;  After sorting, sortIdx[0] holds the slot with the smallest Y (top of screen)
;  and sortIdx[14] the largest (bottom). build_schedule reads in this order so
;  the multiplexer IRQ encounters sprites from top to bottom as the raster descends.
; =====================================================================
sort_sprites
        ; --- flicker fairness: rotate sortIdx left by one slot every frame BEFORE sorting.
        ;     The insertion sort below is STABLE (it stops on '=='), so re-sorting only reshuffles
        ;     the order of entries that share the same Y. On a scanline that overflows the hardware
        ;     limit, the schedule has to drop one sprite; rotating the tie order each frame makes a
        ;     DIFFERENT sprite the dropped one each frame, so the overflow blinks fairly instead of
        ;     one sprite staying permanently invisible. Cost: 15 byte-moves per frame.
        lda sortIdx             ; A = sortIdx[0], the slot we're about to rotate off the front
        sta tmpSlot             ; stash it; it will become the new sortIdx[14]
        ldx #0                  ; X = 0, start of the shift-down loop
fk_rot
        lda sortIdx+1,x         ; A = sortIdx[i+1]
        sta sortIdx,x           ; sortIdx[i] = sortIdx[i+1]   (shift every entry one slot left)
        inx                     ; i++
        cpx #14                 ; stop after writing sortIdx[13] (we never read past sortIdx[14])
        bne fk_rot              ; loop for indices 0..13
        lda tmpSlot             ; recover the old sortIdx[0]
        sta sortIdx+14          ; place it at the end: rotation complete
        lda #1                  ; insertion sort starts at element 1 (element 0 is trivially sorted)
        sta ss_x                ; store outer loop index in memory (X register is used by inner loop)
ss_outer
        lda ss_x                ; load outer loop index (i)
        cmp #15                 ; have we processed all 15 virtual sprite slots?
        bcs ss_done             ; yes: sort complete
        ldx ss_x                ; X = i (index into sortIdx)
        lda sortIdx,x           ; load the virtual slot number at position i
        sta tmpSlot             ; save as "key" slot being inserted into sorted portion
        tay                     ; Y = key slot number (index into vsY array)
        lda vsY,y               ; load vsY[key slot]: the Y coordinate of the key element
        sta sortKey             ; save key's Y value for comparisons in inner loop
        lda ss_x                ; load outer index
        sta sortJ               ; j = i (inner loop starts at outer position, works leftward)
ss_inner
        lda sortJ               ; load inner index j
        beq ss_place            ; j==0: reached front of array, place key here
        tax                     ; X = j
        dex                     ; X = j-1 (look at the element just left of current position)
        lda sortIdx,x           ; load virtual slot number at position j-1
        tay                     ; Y = slot number at j-1
        lda vsY,y               ; load vsY[sortIdx[j-1]]: Y coordinate of left neighbour
        cmp sortKey             ; compare neighbour Y against key Y
        bcc ss_place            ; neighbour Y < key Y: correct position found, insert here
        beq ss_place            ; neighbour Y == key Y: stable sort, insert here (don't swap equals)
        ; sortIdx[j] = sortIdx[j-1]
        lda sortIdx,x           ; load value at position j-1 (neighbour is larger than key)
        ldy sortJ               ; Y = j (destination)
        sta sortIdx,y           ; shift sortIdx[j-1] right into sortIdx[j] to make room
        dec sortJ               ; j-- : continue shifting leftward
        jmp ss_inner            ; keep shifting until correct position found
ss_place
        ldx sortJ               ; X = j: the insertion position found by inner loop
        lda tmpSlot             ; load the key slot that was being inserted
        sta sortIdx,x           ; place key slot at its correct sorted position
        inc ss_x                ; advance outer index to next unsorted element
        jmp ss_outer            ; process next element
ss_done
        rts

; =====================================================================
;  BUILD_SCHEDULE: emit active sprites from sortIdx (Y order) into the
;  BACK schedule buffer, set schCount, swap schFront.
;  Double-buffered: schFront (read by mux_irq) and schBack (written here)
;  alternate each frame so the IRQ always reads a complete, consistent list.
;  schY/schXlo/schXhi/schColor are parallel arrays; each entry corresponds
;  to one active virtual sprite in ascending Y order for the multiplexer.
; =====================================================================
build_schedule
        lda schFront            ; load current front buffer index (0 or 1)
        eor #1                  ; toggle: back = 1-front (the buffer not currently being read)
        sta schBack             ; schBack = index of buffer safe to write this frame
        ; write index -> schBackBase (base = 0 or 15)
        ldx #0                  ; assume back==0: schedule arrays start at offset 0
        lda schBack             ; check which buffer is the back buffer
        beq bs_base0            ; back==0: base offset stays 0
        ldx #15                 ; back==1: base offset = 15 (second half of 30-entry arrays)
bs_base0
        stx schBackBase         ; schBackBase = write pointer into schedule arrays
        stx bsBase              ; bsBase = remember the starting write pointer (to count emits below)
        ldy #0                  ; sortIdx position counter (0..14, iterates sorted virtual slots)
bs_loop
        cpy #15                 ; processed all 15 sorted virtual sprite slots?
        bcs bs_end              ; yes: done building schedule
        lda sortIdx,y           ; load virtual slot number at sorted position Y (top-to-bottom order)
        sta tmpSlot             ; save slot number in scratch
        sty sortJ               ; save sortIdx position (Y register will be reused below)
        ldx tmpSlot             ; X = virtual slot index (into vsActive/vsY/vsXlo/etc.)
        lda vsActive,x          ; is this virtual sprite slot active (1=yes, 0=empty)?
        beq bs_skip             ; inactive slot: don't add to schedule
        ; --- capacity guard ----------------------------------------------------------------
        ; The multiplexer assigns hardware sprites round-robin, so the hw sprite used for this
        ; entry is the SAME one used 7 entries ago. If that earlier sprite is still on screen
        ; (its Y is within SPRSPAN of ours), reprogramming the hw slot now would corrupt it.
        ; In that case we DROP this sprite cleanly (skip it) rather than half-draw two. This only
        ; bites when >7 active sprites fall inside one ~SPRSPAN-line band — i.e. a real overflow.
        lda schBackBase         ; current write pointer
        sec
        sbc bsBase              ; A = how many entries we've emitted so far this frame
        cmp #7                  ; have we emitted at least 7 (one full set of hw sprites 1..7)?
        bcc bs_emit             ; fewer than 7 emitted -> a hardware sprite is still free, no conflict
        lda schBackBase         ; >=7 emitted: find the entry from 7 slots ago (shares our hw sprite)
        sec
        sbc #7                  ; index = schBackBase - 7
        tay                     ; Y = that earlier schedule index
        lda vsY,x               ; A = this sprite's Y (always >= the earlier one; list is Y-sorted)
        sec
        sbc schY,y              ; A = gap between this Y and the sprite reusing-this-hw 7 ago
        cmp #SPRSPAN            ; is the gap big enough that the old sprite has finished drawing?
        bcc bs_skip             ; no -> hw slot still busy -> DROP this sprite (skip emit)
bs_emit
        ; src slot = X (tmpSlot); dst = schBackBase
        ldy schBackBase         ; Y = destination index in the back schedule arrays
        lda vsY,x               ; load virtual sprite Y coordinate
        sta schY,y              ; schY[dst] = vsY[slot] (Y position for multiplexer)
        lda vsXlo,x             ; load virtual sprite X low byte
        sta schXlo,y            ; schXlo[dst] = vsXlo[slot] (X lo for $D000/$D002/etc.)
        lda vsXhi,x             ; load virtual sprite X high bit (9th bit)
        sta schXhi,y            ; schXhi[dst] = vsXhi[slot] (contributes to $D010 MSB mask)
        lda vsColor,x           ; load virtual sprite color index (0-15)
        sta schColor,y          ; schColor[dst] = vsColor[slot] (written to $D027-$D02E)
        inc schBackBase         ; advance write pointer to next schedule entry
bs_skip
        ldy sortJ               ; restore sortIdx position counter
        iny                     ; advance to next sorted slot
        jmp bs_loop             ; process next virtual sprite
bs_end
        ; count = schBackBase - base
        lda schBackBase         ; load final write pointer (= base + number of active sprites)
        ldx schBack             ; check which buffer was the back
        beq bs_cnt0             ; back==0: count = schBackBase directly (base was 0)
        sec                     ; back==1: subtract base offset 15 to get true count
        sbc #15                 ; count = schBackBase - 15 (number of active entries written)
bs_cnt0
        ldx schBack             ; X = back buffer index again (A may have been modified)
        sta schCount,x          ; schCount[back] = number of active sprites in this schedule
        ; swap front
        lda schBack             ; load back buffer index
        sta schFront            ; promote back to front: mux_irq will read this next frame
        rts

; ---------------------------------------------------------------------
; spawn_enemies: countdown; on 0, spawn one enemy into a free slot 6..10
; from the wave tables, then reset the timer.
; ---------------------------------------------------------------------
spawn_enemies
        lda bossState           ; load boss-active flag (0=inactive, non-zero=boss present)
        beq se_go               ; boss inactive: proceed with enemy spawning
        rts                     ; boss is live: enemies suppressed while boss occupies slots 6-10
se_go
        dec spawnTimer          ; count down between-spawn interval
        beq se_fire             ; timer expired: time to spawn a new enemy
        rts                     ; not yet time, return early
se_fire
        ldx #6                  ; find free enemy slot (virtual slots 6..10); start at slot 6
se_find
        cpx #11                 ; past end of enemy slot range (6-10)?
        bcs se_reset            ; none free -> just reset timer
        lda vsActive,x          ; is this virtual sprite slot unoccupied?
        beq se_spawn            ; zero = free: spawn here
        inx                     ; slot in use, try next
        jmp se_find             ; continue linear search through slots
se_spawn
        ldy spawnIndex          ; Y = index into wave descriptor tables (waveY / wavePattern)
        lda #$54                ; X = 340 ($154): lo=$54, hi=1 (right edge)
        sta vsXlo,x             ; store 16-bit X low byte: spawn just off right edge of screen
        lda #1
        sta vsXhi,x             ; store 16-bit X high byte (340 = $0154, needs >8 bits)
        lda waveY,y             ; fetch this wave entry's Y spawn row
        sta vsY,x               ; set sprite Y position
        sta vsBaseY,x           ; also save as base Y (sine-wave pattern oscillates around this)
        lda wavePattern,y       ; fetch movement pattern: 0=straight, 1=sine, 2=zigzag
        sta vsPattern,x         ; store pattern in slot for update_enemies to use
        lda #0
        sta vsPhase,x           ; reset sine/zigzag phase counter to 0 for fresh start
        sta vsState,x           ; state 0 = alive (non-zero = exploding)
        lda #ENEMY_COLOR
        sta vsColor,x           ; set enemy sprite color
        lda #1
        sta vsActive,x          ; mark slot active (visible and updated)
        sta vsVY,x              ; default zigzag velocity = +1 (starts moving downward)
        iny                     ; advance wave index (wrap at waveN)
        cpy #waveN              ; reached end of wave descriptor table?
        bcc se_idxok            ; no: keep incremented index
        ldy #0                  ; yes: wrap back to start of wave table
se_idxok
        sty spawnIndex          ; save updated wave index for next spawn
se_reset
        lda #SPAWN_INTERVAL     ; reload spawn countdown constant
        sta spawnTimer          ; reset timer for next spawn cycle
        rts

; ---------------------------------------------------------------------
; update_enemies: slots 6..10. Exploding -> count down & despawn.
; Alive -> move left by ENEMY_SPEED, despawn off left edge. Vertical
; movement by pattern is added in Task 2 (ue_vert is straight/no-op here).
; ---------------------------------------------------------------------
update_enemies
        lda bossState           ; check if boss is active
        beq ue_go               ; boss inactive: process enemies normally
        rts                     ; boss active: skip entirely (slots 6-10 belong to boss)
ue_go
        ldx #6                  ; start at first enemy slot (6)
ue_loop
        cpx #11                 ; processed all 5 enemy slots (6-10)?
        bcc ue_notdone          ; no: keep processing
        jmp ue_done             ; yes: all slots handled
ue_notdone
        lda vsActive,x          ; is this slot in use?
        bne ue_isactive         ; non-zero = active: process it
        jmp ue_next             ; inactive: skip to next slot
ue_isactive
        lda vsState,x           ; check slot state: 0=alive, non-zero=exploding
        beq ue_alive            ; state 0: alive, do movement
        ; exploding: count down, despawn at 0
        dec vsExplodeTimer,x    ; decrement explosion animation frame counter
        bne ue_next             ; still counting down: leave on screen
        jsr ue_despawn          ; counter reached 0: remove sprite from screen
        jmp ue_next
ue_alive
        ; X -= ENEMY_SPEED (16-bit, move left)
        lda vsXlo,x             ; load 16-bit X position low byte
        sec                     ; set carry so SBC borrows correctly
        sbc #ENEMY_SPEED        ; subtract horizontal speed (moves enemy leftward each frame)
        sta vsXlo,x             ; store updated low byte
        lda vsXhi,x             ; load X high byte
        sbc #0                  ; propagate borrow from low byte into high byte
        sta vsXhi,x             ; store updated high byte
        ; off-left despawn: hi==0 and lo<20, or hi==$ff (underflow)
        lda vsXhi,x             ; re-read high byte to check despawn conditions
        bne ue_xhi              ; non-zero: could be underflow ($ff), check separately
        lda vsXlo,x             ; hi==0: enemy is in range 0-255; check left boundary
        cmp #20                 ; is X low byte < 20 (past left edge of playfield)?
        bcs ue_vert             ; X >= 20: still on screen, proceed to vertical movement
        jsr ue_despawn          ; X < 20 with hi=0: scrolled off left edge, despawn
        jmp ue_next
ue_xhi
        cmp #$ff                ; A = vsXhi: did the 16-bit X underflow past 0?
        bne ue_vert             ; hi==1: enemy is to the right of screen center (valid), do vertical
        jsr ue_despawn          ; hi==$ff: X underflowed below zero, despawn
        jmp ue_next
ue_vert
        lda vsPattern,x         ; load this enemy's movement pattern
        beq ue_next             ; pattern 0 = straight flight: no vertical movement
        cmp #1                  ; pattern 1 = sine wave?
        beq ue_sine             ; yes: use sine-table oscillation
        ; --- pattern 2: zigzag (Y += vsVY, bounce [54,210]) ---
        ; vsVY holds the current vertical velocity: +1 (down) or -1 (up, as 8-bit $FF).
        ; Enemy bounces between Y=70 (near top of play area) and Y=210 (near bottom).
        lda vsY,x               ; load current sprite Y
        clc
        adc vsVY,x              ; add velocity: +1 moves down, $FF (+= -1) moves up
        sta vsY,x               ; store new Y
        cmp #70                 ; did Y drop below top boundary (Y < 70)?
        bcs ue_zz_top           ; Y >= 70: not at top, check bottom
        lda #70                 ; clamp: force Y to top boundary
        sta vsY,x
        jsr ue_negVY            ; reverse velocity: was going up, now goes down
        jmp ue_next
ue_zz_top
        cmp #211                ; did Y exceed bottom boundary (Y >= 211)?
        bcc ue_next             ; Y < 211: within play area, no bounce needed
        lda #210                ; clamp: force Y to bottom boundary
        sta vsY,x
        jsr ue_negVY            ; reverse velocity: was going down, now goes up
        jmp ue_next
ue_sine
        ; Sine-wave vertical movement: a 64-entry sine table gives a smooth oscillation.
        ; phase steps 0..63 each frame (wraps via AND #63 = mod 64).
        ; Y = vsBaseY + sineTable[phase]: enemy oscillates above and below its spawn row.
        lda vsPhase,x           ; load current phase counter (0-63)
        clc
        adc #1                  ; increment phase by 1 each frame
        and #63                 ; wrap to 0..63: keeps index in table bounds
        sta vsPhase,x           ; save updated phase
        tay                     ; transfer phase to Y register for table index
        lda sineTable,y         ; fetch sine displacement (signed offset, centered around 0)
        clc
        adc vsBaseY,x           ; add to base Y (enemy's spawn row): Y = baseY + sin(phase)
        sta vsY,x               ; store resulting screen Y position
        jmp ue_next
ue_next
        inx                     ; advance to next enemy slot
        jmp ue_loop             ; continue processing remaining slots
ue_done
        rts

; despawn enemy in X: inactive + park Y off-screen
ue_despawn
        lda #0
        sta vsActive,x          ; mark slot inactive (free for next spawn to reuse)
        lda #255
        sta vsY,x               ; move sprite Y to 255: below visible screen, effectively hidden
        rts

; negate vsVY[x] (zigzag bounce)
ue_negVY
        lda #0
        sec                     ; set carry so the subtract is a full two's-complement negate
        sbc vsVY,x              ; A = 0 - vsVY: flips +1 -> $FF (-1) and $FF (-1) -> +1
        sta vsVY,x              ; store reversed velocity back into slot
        rts

; ---------------------------------------------------------------------
; enemy_fire: countdown; on 0, fire a straight-left bullet from a live
; enemy (cycling via enemyFireIndex 6..10) into a free enemy-bullet slot
; (11..14). X = enemy-bullet slot, Y = enemy slot.
; ---------------------------------------------------------------------
enemy_fire
        lda bossState           ; check if boss is active
        beq ef_go               ; boss inactive: enemies may fire
        rts                     ; boss active: suppress enemy fire (boss_fire handles bullets)
ef_go
        dec enemyFireTimer      ; count down between-shots interval
        beq ef_fire             ; timer expired: fire a bullet now
        rts                     ; not yet time
ef_fire
        ldx #11                 ; find free enemy-bullet slot 11..14; start at slot 11
ef_findbul
        cpx #15                 ; past end of bullet slot range (11-14)?
        bcs ef_reset            ; none free: reset timer and return without firing
        lda vsActive,x          ; is this bullet slot vacant?
        beq ef_havebul          ; zero = free: use this slot
        inx                     ; occupied: try next slot
        jmp ef_findbul
ef_havebul
        ; scan up to 5 enemies starting at enemyFireIndex for a live one
        ldy enemyFireIndex      ; Y = next enemy slot to try (cycles 6-10 for fair distribution)
        lda #5
        sta ef_scan             ; ef_scan = max enemies to check before giving up
ef_findenemy
        cpy #11                 ; past slot 10? (wrap Y back into range 6..10)
        bcc ef_yok              ; Y still in range
        ldy #6                  ; wrap: past slot 10, restart at slot 6
ef_yok
        lda vsActive,y          ; is this enemy slot active?
        beq ef_skipenemy        ; no: skip it
        lda vsState,y           ; is enemy alive (state 0) vs. exploding (non-zero)?
        beq ef_spawn            ; state 0 = alive and can fire
ef_skipenemy
        iny                     ; try next enemy
        dec ef_scan             ; one fewer to check
        bne ef_findenemy        ; keep scanning if remaining count > 0
        jmp ef_reset            ; exhausted all 5 slots without finding a live enemy
ef_spawn
        lda vsXlo,y             ; spawn enemy bullet at enemy position
        sta vsXlo,x             ; bullet starts at same X low byte as firing enemy
        lda vsXhi,y
        sta vsXhi,x             ; bullet X high byte: same 16-bit X as enemy
        lda vsY,y
        sta vsY,x               ; bullet Y same as enemy (fires from enemy's vertical position)
        lda #EBULLET_COLOR
        sta vsColor,x           ; set enemy bullet color
        lda #1
        sta vsActive,x          ; activate bullet slot (update_enemy_bullets will move it left)
        iny                     ; advance fire index past this enemy (ensures cycling)
        cpy #11                 ; past slot 10?
        bcc ef_idxok            ; no wrap needed
        ldy #6                  ; wrap back to slot 6
ef_idxok
        sty enemyFireIndex      ; save updated cycling index for next call
ef_reset
        lda #ENEMY_FIRE_INTERVAL ; reload fire-rate constant
        sta enemyFireTimer      ; reset timer
        rts

; place the 5 boss pieces (slots 6..10) at the anchor: same X, Y spread by bossOffY.
; color = white while bossFlash>0, else BOSS_COLOR.
; NOTE: the boss reuses enemy virtual sprite slots 6-10 for its 5 body pieces.
; bossState is non-zero whenever the boss is alive, which causes update_enemies and
; enemy_fire to return immediately, so there is no conflict over these slots.
boss_place_pieces
        ldx #0                  ; piece index 0..4 (5 body pieces)
bpp_loop
        cpx #5                  ; all 5 pieces placed?
        bcs bpp_done
        txa                     ; A = piece index (0-4)
        clc
        adc #6                  ; A = virtual sprite slot (6-10)
        tay                     ; Y = slot index for vsXlo/vsY/vsColor etc.
        lda bossXlo
        sta vsXlo,y             ; all 5 pieces share the same X low byte (cluster moves together)
        lda bossXhi
        sta vsXhi,y             ; all 5 pieces share the same X high byte
        lda bossY               ; boss anchor Y (set each frame by boss_bob)
        clc
        adc bossOffY,x          ; add signed per-piece Y offset: spreads pieces into a vertical cluster
        sta vsY,y               ; store individual piece Y position
        lda bossFlash           ; hit-flash counter: non-zero = currently flashing
        beq bpp_normalcol       ; zero: use normal boss color
        lda #1                  ; VIC-II color 1 = white: flash on hit
        jmp bpp_setcol
bpp_normalcol
        lda #BOSS_COLOR         ; normal boss color when not flashing
bpp_setcol
        sta vsColor,y           ; write color to this piece's virtual sprite slot
        lda #1
        sta vsActive,y          ; ensure piece slot is active (visible)
        lda #0
        sta vsState,y           ; state 0 = alive (not in explosion animation)
        inx                     ; next piece index
        jmp bpp_loop
bpp_done
        rts

; bob the anchor Y around bossYCenter via the sine table
; Called every frame during BS_FIGHT. bossPhase steps 0-63 through a 64-entry
; sine table, producing a smooth cyclic vertical oscillation of the whole cluster.
boss_bob
        inc bossPhase           ; advance bob phase counter by 1 each frame
        lda bossPhase
        and #63                 ; wrap to 0..63: mod-64 keeps index in table
        sta bossPhase           ; store wrapped phase
        tay                     ; Y = phase index into sineTable
        lda sineTable,y         ; fetch sine displacement (signed 8-bit offset around 0)
        clc
        adc bossYCenter         ; bossY = bossYCenter + sin(phase): smooth oscillation
        sta bossY               ; update boss anchor Y; boss_place_pieces distributes pieces around it
        rts

; boss_fire: on timer, spawn straight-left bullets into free slots 11..14
; from successive boss-piece Y positions (a vertical volley).
boss_fire
        dec bossFireTimer       ; count down between volleys
        beq bf_fire             ; timer expired: launch a volley
        rts                     ; not yet time
bf_fire
        ldx #11                 ; start scanning enemy-bullet slots from 11
        ldy #6                  ; start from first boss-piece slot (6)
bf_loop
        cpx #15                 ; past all 4 bullet slots (11-14)?
        bcs bf_done             ; yes: volley dispatch complete
        lda vsActive,x          ; is this bullet slot free?
        bne bf_nextbul          ; occupied: skip it, try next bullet slot
        lda vsXlo,y             ; copy boss piece X low byte to bullet (fired from piece position)
        sta vsXlo,x
        lda vsXhi,y             ; copy boss piece X high byte to bullet
        sta vsXhi,x
        lda vsY,y               ; each piece is at a different Y: bullet originates from piece's row
        sta vsY,x               ; bullet Y = this piece's Y (creates a vertical spread of bullets)
        lda #EBULLET_COLOR
        sta vsColor,x           ; set bullet color
        lda #1
        sta vsActive,x          ; activate bullet slot (will be moved left by update_enemy_bullets)
        iny                     ; advance to next boss piece slot (6..10 cycling)
        cpy #11                 ; past slot 10?
        bcc bf_nextbul          ; no wrap needed
        ldy #6                  ; wrap piece index back to slot 6
bf_nextbul
        inx                     ; advance to next bullet slot
        jmp bf_loop             ; continue filling remaining bullet slots
bf_done
        lda #BOSS_FIRE_INTERVAL ; reload volley interval constant
        sta bossFireTimer       ; arm timer for next volley
        rts

; boss_take_hit: despawn the player bullet (slot X), drain HP, flash;
; HP 0 -> dying. Only counts while fighting.
boss_take_hit
        lda #0
        sta vsActive,x          ; deactivate the player bullet that struck the boss
        lda #255
        sta vsY,x               ; park bullet Y at 255 (off screen) so it disappears
        lda bossState           ; read current boss state
        cmp #BS_FIGHT           ; is boss currently in FIGHT state?
        bne bth_ret             ; not fighting (ENTER or DYING): ignore this hit
        dec bossHP              ; shared HP pool: any piece hit drains the same counter
        lda #BOSS_FLASH_FRAMES
        sta bossFlash           ; start hit-flash timer: boss_place_pieces colors pieces white
        lda bossHP              ; check remaining HP
        bne bth_ret             ; HP > 0: boss survives this hit
        lda #BS_DYING           ; HP exhausted: transition to dying/explosion state
        sta bossState
        lda #BOSS_DEATH_FRAMES
        sta bossDeathTimer      ; set explosion animation duration counter
bth_ret
        rts

; boss_spawn: initialise an entering boss
boss_spawn
        lda #BS_ENTER           ; state = ENTER: boss slides in from right edge
        sta bossState
        lda #BOSS_HP
        sta bossHP              ; initialise full shared HP (e.g. 5 hits to kill)
        lda #$54                ; X = 340 (hi=1, lo=$54): start just off right edge of screen
        sta bossXlo             ; 16-bit X low byte ($54 = 84)
        lda #1
        sta bossXhi             ; 16-bit X high byte (1 * 256 + 84 = 340)
        lda #130
        sta bossY               ; initial Y position: vertical centre of the play area
        sta bossYCenter         ; bob center locked to this row; boss_bob oscillates around it
        lda #0
        sta bossPhase           ; start sine bob phase at 0 (beginning of cycle)
        sta bossFlash           ; no hit-flash active at spawn
        lda #BOSS_FIRE_INTERVAL
        sta bossFireTimer       ; arm the first fire-volley timer
        jsr sfx_boss            ; trigger boss-entry SID sound effect
        jsr boss_place_pieces   ; immediately place all 5 pieces so they appear on screen
        rts

; boss_update: state machine, called each frame from main_loop.
; States: INACTIVE(0) -> BS_ENTER -> BS_FIGHT -> BS_DYING -> back to INACTIVE(0)
boss_update
        lda bossState           ; load current boss state
        bne bu_active           ; non-zero: boss is active, dispatch to appropriate handler
        ; inactive: trigger after enough kills
        lda killCount           ; kills accumulated since last boss defeat (or game start)
        cmp #BOSS_KILL_THRESHOLD ; have we reached the threshold to spawn the boss?
        bcc bu_ret              ; not enough kills yet: stay inactive
        jsr boss_spawn          ; threshold reached: spawn and initialise the boss
bu_ret
        rts
bu_active
        cmp #BS_ENTER           ; is boss in ENTER state?
        beq bu_enter            ; yes: slide it onto the screen
        cmp #BS_FIGHT           ; is boss in FIGHT state?
        beq bu_fight            ; yes: bob, fire, track flash
        jmp bu_dying            ; otherwise must be BS_DYING: run death animation
bu_enter
        lda bossXlo             ; slide left (hi stays 1 from 340->300)
        sec
        sbc #BOSS_ENTER_SPEED   ; subtract entry speed: moves boss leftward toward fight position
        sta bossXlo             ; store updated X low byte
        lda bossXhi
        sbc #0                  ; propagate any borrow into high byte
        sta bossXhi             ; store updated X high byte
        lda bossXlo
        cmp #$2d                ; lo < $2d -> reached fight X (300=$12c, lo byte = $2c)
        bcs bu_enter_place      ; not yet at fight X: keep sliding
        lda #BS_FIGHT           ; arrived at fight position: transition to FIGHT state
        sta bossState
bu_enter_place
        jsr boss_place_pieces   ; update all 5 piece positions each entry frame
        rts
bu_fight
        jsr boss_bob            ; advance sine phase and update bossY (vertical bobbing)
        jsr boss_fire           ; decrement fire timer; spawn a bullet volley when it expires
        lda bossFlash           ; check hit-flash countdown
        beq bu_fight_place      ; zero: no flash pending, skip decrement
        dec bossFlash           ; count down flash duration (pieces shown white until this reaches 0)
bu_fight_place
        jsr boss_place_pieces   ; refresh all 5 pieces: positions + color (white if flashing)
        rts

bu_dying
        dec bossDeathTimer      ; count down death/explosion animation duration
        beq bd_done             ; timer reached 0: finalize and reset
        ; keep pieces flashing white during the explosion
        lda #BOSS_FLASH_FRAMES
        sta bossFlash           ; force flash counter high every frame: pieces stay white throughout
        jsr boss_place_pieces   ; update pieces with forced white color each dying frame
        rts
bd_done
        ; despawn boss pieces
        ldx #6                  ; start at first boss-piece slot (6)
bd_clear
        cpx #11                 ; past last boss-piece slot (10)?
        bcs bd_cleared          ; yes: all 5 pieces cleared
        lda #0
        sta vsActive,x          ; deactivate slot: free for enemy reuse in next wave
        lda #255
        sta vsY,x               ; park sprite Y at 255: off bottom of screen, hidden
        inx                     ; next slot
        jmp bd_clear
bd_cleared
        lda #0
        sta bossState           ; return boss to INACTIVE: enemies can spawn again
        sta killCount           ; reset kill counter so next boss spawns after N more kills
        jsr sfx_explosion       ; play large explosion SID sound
        ; +1000 score bonus (BCD, IRQ-safe)
        php                     ; save current processor flags (preserves I flag state)
        sei                     ; disable IRQ: protect the multi-byte BCD addition from raster-IRQ race
        sed                     ; set decimal (BCD) mode: ADC now operates in packed BCD arithmetic
        clc                     ; clear carry before addition
        lda score+1             ; load middle byte of 3-byte BCD score (hundreds/tens digit pair)
        adc #$10                ; BCD add $10 = decimal 10 tens = +1000 to the overall score
        sta score+1             ; store updated middle score byte
        lda score+2             ; load high byte of BCD score (ten-thousands digit pair)
        adc #0                  ; propagate BCD carry from middle byte (handles score rollover >=10000)
        sta score+2             ; store updated high score byte
        plp                     ; restore processor flags: re-enables IRQs and clears decimal mode
        rts

; ---------------------------------------------------------------------
; update_enemy_bullets: slots 11..14 move LEFT; despawn off the left edge.
; ---------------------------------------------------------------------
update_enemy_bullets                    ; move enemy/boss bullet slots 11-14 one step left per frame
        ldx #11                         ; X = first enemy bullet virtual-sprite slot (slots 11-14)
ueb_loop
        cpx #15                         ; tested all 4 enemy bullet slots (11,12,13,14)?
        bcs ueb_done                    ; X >= 15 -> all slots done, exit loop
        lda vsActive,x                  ; load active flag for slot X (0=inactive, 1=live bullet)
        beq ueb_next                    ; slot is empty -> skip to next slot
        lda vsXlo,x             ; X -= EBULLET_SPEED (16-bit, move left); load X-position low byte
        sec                             ; set carry before SBC so borrow is computed correctly
        sbc #EBULLET_SPEED              ; subtract bullet speed from lo byte; bullet travels left each frame
        sta vsXlo,x                     ; store decremented X lo byte back to sprite array
        lda vsXhi,x                     ; load X position high byte for 16-bit borrow propagation
        sbc #0                          ; subtract borrow from hi byte (completes 16-bit decrement)
        sta vsXhi,x                     ; store updated hi byte back
        lda vsXhi,x             ; off-left despawn; reload hi byte to check off-screen condition
        bne ueb_hi                      ; hi != 0 -> underflowed ($FF) or on far right ($01); check further
        lda vsXlo,x                     ; hi == 0: check lo for minimum visible X (left-edge guard)
        cmp #8                          ; lo < 8 means X < 8, which is off the left playfield edge
        bcs ueb_next            ; lo>=8 -> on screen; bullet still visible, do not despawn
        jsr ue_despawn                  ; lo < 8 with hi=0: bullet exited left edge, remove it
        jmp ueb_next                    ; continue to next slot after despawn
ueb_hi
        cmp #$ff                ; A = vsXhi; $ff = underflow -> despawn; 1 = on right; hi was non-zero
        bne ueb_next                    ; hi == $01 means X is 256-511, still on screen; skip despawn
        jsr ue_despawn                  ; hi == $FF: X underflowed below zero, bullet has left the left edge
ueb_next
        inx                             ; advance to next virtual sprite slot
        jmp ueb_loop                    ; check the next enemy bullet slot
ueb_done
        rts                             ; all four enemy bullet slots processed; return to caller

; update_bullets: fire on space (cooldown-gated) into a free slot 0..5; move live bullets
; right; despawn past the right edge (X > 344 = $158).
update_bullets
        ; --- cooldown ---
        lda fireCool                    ; load fire-rate cooldown counter (0 = player may fire)
        beq ub_canfire                  ; cooldown exhausted -> check Space key
        dec fireCool                    ; decrement countdown timer (one frame closer to firing again)
        jmp ub_move                     ; still in cooldown -> skip fire logic, go move existing bullets
ub_canfire
        lda keyrow7                     ; load CIA keyboard matrix row-7 scan byte
        and #%00010000          ; space (active low); isolate bit 4 = Space key (C64 rows, active-low)
        bne ub_move             ; not pressed; bit high means Space not held -> skip firing
        ; find a free bullet slot 0..5
        ldx #0                          ; begin search from slot 0 (first player bullet slot)
ub_find
        cpx #6                          ; have we checked all slots 0-5?
        bcs ub_move             ; no free slot; all 6 slots occupied -> cannot fire this frame
        lda vsActive,x                  ; load active flag for candidate slot X
        beq ub_spawn                    ; active==0 -> this slot is free, use it for the new bullet
        inx                             ; slot occupied, try the next one
        jmp ub_find                     ; loop back to check next slot
ub_spawn
        ; spawn at ship nose: X = player_x + 24, Y = player_y + 8
        lda player_x                    ; load player ship X position low byte
        clc                             ; clear carry for upcoming 16-bit addition
        adc #24                         ; add 24 px to place bullet at the ship's right nose
        sta vsXlo,x                     ; store bullet spawn X lo byte into the chosen slot
        lda player_x_hi                 ; load player X high byte
        adc #0                          ; propagate carry from lo addition into hi byte
        sta vsXhi,x                     ; store bullet spawn X hi byte
        lda player_y                    ; load player ship Y position (8-bit VIC-II sprite Y)
        clc                             ; clear carry for addition
        adc #8                          ; add 8 px to vertically center bullet on the ship sprite
        sta vsY,x                       ; store bullet spawn Y into slot
        lda #7                  ; yellow; sprite color index 7 = yellow on C64
        sta vsColor,x                   ; assign yellow color to this bullet's virtual sprite slot
        lda #1                          ; active flag value = 1
        sta vsActive,x                  ; mark slot as live (bullet is now active)
        lda #6                  ; cooldown frames (tunable); 6 frames between shots limits fire rate
        sta fireCool                    ; arm cooldown so player cannot fire again for 6 frames
        jsr sfx_fire                    ; trigger SID fire sound effect (frequency sweep on a SID voice)
ub_move
        ; move all live bullets (slots 0..5) right by 4; despawn past $158
        ldx #0                          ; start from slot 0 (first player bullet slot)
ub_mloop
        cpx #6                          ; past last player bullet slot (0..5)?
        bcs ub_done                     ; yes -> all slots checked, exit
        lda vsActive,x                  ; load active flag for this slot
        beq ub_mnext                    ; slot inactive -> skip movement
        lda vsXlo,x                     ; load bullet X position lo byte
        clc                             ; clear carry for 16-bit addition
        adc #4                          ; advance bullet 4 pixels to the right per frame
        sta vsXlo,x                     ; store updated X lo byte
        lda vsXhi,x                     ; load X hi byte for carry propagation
        adc #0                          ; add carry to hi byte (handles 16-bit crossing of 256-pixel boundary)
        sta vsXhi,x                     ; store updated X hi byte (X position is full 16-bit)
        ; despawn if X > 344 ($158): hi>=2, or (hi==1 and lo>=$59)
        lda vsXhi,x                     ; load hi byte to test right-edge condition
        cmp #2                          ; hi >= 2 means X >= 512, well past the 320-pixel-wide right edge
        bcs ub_kill                     ; hi >= 2 -> definitely off-screen right, despawn bullet
        cmp #1                          ; is hi < 1 (i.e., hi == 0)?
        bcc ub_mnext            ; hi==0 -> on screen; X < 256, bullet still on visible playfield
        lda vsXlo,x                     ; hi == 1: load lo to check if X >= $159 (= 345 px, past right edge)
        cmp #$59                        ; compare lo with $59 (so $0159 = 345, just past right edge)
        bcc ub_mnext                    ; lo < $59 -> X < 345, bullet is still on screen
ub_kill
        lda #0                          ; zero for deactivation
        sta vsActive,x                  ; clear active flag: bullet is removed from play
        lda #255                        ; sentinel Y value (off-screen)
        sta vsY,x               ; park (sorts last); Y=255 makes the multiplexer sort this slot last/ignore it
ub_mnext
        inx                             ; advance to next slot
        jmp ub_mloop                    ; loop back to process next player bullet slot
ub_done
        rts                             ; all player bullet movement done; return to caller

; ---------------------------------------------------------------------
; check_hits: each live bullet (0..5) vs each alive enemy (6..10).
; bounding box |dX|<HITW and |dY|<HITH -> bullet despawns, enemy explodes.
; X = bullet slot, Y = enemy slot.
; ---------------------------------------------------------------------
check_hits
        ldx #0                          ; start outer loop: bullet slot 0 (first player bullet)
ch_bloop
        cpx #6                          ; all 6 bullet slots (0-5) tested?
        bcc ch_notdone1                 ; not yet -> continue checking this bullet slot
        jmp ch_done                     ; all bullet slots tested -> exit routine
ch_notdone1
        lda vsActive,x                  ; load active flag for bullet slot X
        bne ch_notbnext1                ; bullet is live -> proceed to test against enemies
        jmp ch_bnext                    ; bullet slot empty -> skip to next bullet
ch_notbnext1
        ldy #6                          ; start inner loop: enemy slot 6 (first enemy/boss slot)
ch_eloop
        cpy #11                         ; all 5 enemy slots (6-10) checked for this bullet?
        bcc ch_notbnext2                ; not yet -> check this enemy
        jmp ch_bnext                    ; no hit found for this bullet -> advance to next bullet
ch_notbnext2
        lda vsActive,y                  ; load active flag for enemy slot Y
        bne ch_notenext1                ; enemy is live -> test collision
        jmp ch_enext                    ; enemy slot empty -> advance to next enemy
ch_notenext1
        lda vsState,y                   ; load enemy state (0=normal/alive, 1=exploding)
        beq ch_state0                   ; state 0 = alive and collidable, proceed
        jmp ch_enext            ; enemy already exploding; already dying -> skip (can't be hit twice)
ch_state0
        ; --- 16-bit dX = enemyX - bulletX ---
        ; 16-bit bounding-box X test: X coordinates are 16-bit (hi+lo) because the playfield
        ; scrolls and sprite X can exceed 255.  Compute signed dX, then negate if negative
        ; to get |dX|.  If |dX| >= HITW the sprites are too far apart horizontally -> no hit.
        lda vsXlo,y                     ; load enemy X position lo byte
        sec                             ; set carry for 16-bit subtraction
        sbc vsXlo,x                     ; dX_lo = enemyXlo - bulletXlo
        sta chDlo                       ; save dX lo byte to temp variable chDlo
        lda vsXhi,y                     ; load enemy X position hi byte
        sbc vsXhi,x                     ; dX_hi = enemyXhi - bulletXhi - borrow (full 16-bit subtract)
        sta chDhi                       ; save dX hi byte to temp variable chDhi
        bpl ch_xpos             ; dX >= 0; N flag clear -> result positive, enemy right of bullet
        ; negate 16-bit
        ; dX was negative (enemy left of bullet); negate chDhi:chDlo to obtain |dX|
        lda #0                          ; prepare to negate lo byte: compute 0 - chDlo
        sec                             ; set carry so SBC acts as proper two's-complement negate
        sbc chDlo                       ; negated lo byte; sets borrow if chDlo was non-zero
        sta chDlo                       ; store |dX| lo byte
        lda #0                          ; prepare to negate hi byte
        sbc chDhi                       ; negated hi = (0 - chDhi - borrow); completes 16-bit negation
        sta chDhi                       ; store |dX| hi byte; chDhi:chDlo = |enemyX - bulletX|
ch_xpos
        lda chDhi                       ; load |dX| high byte
        bne ch_enext            ; |dX| >= 256 -> no hit; hi != 0 means separation >= 256 px, far miss
        lda chDlo                       ; hi == 0: |dX| fits in 8 bits; load lo for threshold compare
        cmp #HITW                       ; compare |dX| against hit-box half-width constant HITW
        bcs ch_enext            ; |dX| >= HITW -> no hit; sprites too far apart horizontally
        ; --- 8-bit |dY| = |enemyY - bulletY| ---
        ; Y is 8-bit (VIC-II sprite Y register is 0-255), so single-byte absolute difference suffices.
        lda vsY,y                       ; load enemy sprite Y position (8-bit)
        sec                             ; set carry for 8-bit subtraction
        sbc vsY,x                       ; dY = enemyY - bulletY (signed 8-bit result in A)
        bpl ch_ypos                     ; result >= 0 -> dY positive, no negation needed
        eor #$ff                        ; flip all bits (one's complement, first step of abs negation)
        clc                             ; clear carry before adding 1
        adc #1                  ; two's complement abs; +1 completes two's-complement negation -> A = |dY|
ch_ypos
        cmp #HITH                       ; compare |dY| against hit-box half-height constant HITH
        bcs ch_enext            ; |dY| >= HITH -> no hit; sprites too far apart vertically
        ; --- HIT ---
        ; Both conditions met: |dX| < HITW and |dY| < HITH -> bounding boxes overlap -> collision
        lda bossState                   ; load boss state-machine variable (0=INACTIVE, no boss on screen)
        beq ch_normalkill       ; no boss -> normal enemy kill; bossState==0 -> normal enemy path
        jsr boss_take_hit       ; boss piece hit: drain HP, despawn bullet X; delegate to boss hit logic
        jmp ch_bnext                    ; bullet consumed by boss-hit handler -> next bullet
ch_normalkill
        ; --- explode enemy, despawn bullet ---
        lda #1                          ; explosion state value (vsState==1 = exploding)
        sta vsState,y                   ; set enemy into exploding state (locks it out of collision/movement)
        lda #EXPLODE_FRAMES             ; load explosion animation duration in frames
        sta vsExplodeTimer,y            ; start explosion countdown timer for this enemy slot
        lda #EXPLODE_COLOR              ; load explosion sprite color (bright flash)
        sta vsColor,y                   ; switch enemy sprite to explosion color
        lda #0                          ; zero for deactivation
        sta vsActive,x                  ; deactivate bullet slot X (bullet spent on this kill)
        lda #255                        ; off-screen Y sentinel value
        sta vsY,x                       ; park bullet Y at 255 so sprite multiplexer ignores it
        jsr sfx_explosion               ; trigger SID explosion sound effect
        ; --- award points (BCD); sei so an IRQ can't run in decimal mode ---
        ; IRQ-SAFE BCD SCORE ADD:
        ;   On the 6502 the D (decimal) flag is global and affects IRQ handlers.
        ;   If an IRQ fires while D=1, any ADC/SBC inside the handler produces BCD
        ;   results instead of binary, silently corrupting any arithmetic there.
        ;   Guard: PHP saves current flags (including I and D), SEI prevents IRQs,
        ;   SED enables BCD, the addition runs safely, then PLP restores the original
        ;   flags atomically -- clearing D and re-enabling interrupts in one instruction.
        php                             ; push processor status: preserves I and D flags for PLP restoration
        sei                             ; disable IRQs: no interrupt may fire while D flag is set
        sed                             ; set D flag: switch to BCD mode (ADC now produces packed-BCD results)
        clc                             ; clear carry before first BCD addition
        lda score                       ; load BCD score byte 0 (packed digits 01-02: ones and tens)
        adc #SCORE_PER_KILL             ; add kill-point bonus in BCD (e.g. $10=10 pts, $50=50 pts)
        sta score                       ; store updated BCD score byte 0
        lda score+1                     ; load BCD score byte 1 (packed digits 03-04: hundreds, thousands)
        adc #0                          ; propagate BCD carry from byte 0 into byte 1
        sta score+1                     ; store updated BCD score byte 1
        lda score+2                     ; load BCD score byte 2 (packed digits 05-06: ten-K, hundred-K)
        adc #0                          ; propagate BCD carry from byte 1 into byte 2
        sta score+2                     ; store updated BCD score byte 2
        plp                     ; restores D=0 and re-enables IRQs; pull flags: exits BCD mode, restores I flag
        inc killCount                   ; increment kill counter (triggers boss spawn after N kills)
        jmp ch_bnext            ; this bullet consumed -> next bullet; done with this bullet
ch_enext
        iny                             ; advance inner loop to next enemy slot
        jmp ch_eloop                    ; test this bullet against the next enemy
ch_bnext
        inx                             ; advance outer loop to next bullet slot
        jmp ch_bloop                    ; test next bullet against all enemies
ch_done
        rts                             ; all bullet/enemy collision checks complete; return

; =====================================================================
;  SCROLL STEP  (once per frame)
;  - always: build a slice of the back buffer
;  - fine_x 7..1: just decrement and set $D016
;  - fine_x 0:    flip buffers, reset fine to 7, reset build_row
; =====================================================================
; SMOOTH-SCROLL MECHANIC (summary):
;   Two mechanisms work together to give pixel-smooth horizontal scrolling:
;   1. FINE scroll ($D016 SCROLX bits 0-2): shifts the VIC-II display 0-7
;      pixels left within the current character grid.  fine_x counts 7..0,
;      decrementing once per frame.  The IRQ caller writes fine_x into bits
;      0-2 of $D016 after each call, giving a 1-pixel leftward shift per frame.
;   2. COARSE scroll (buffer flip every 8 frames): when fine_x underflows from
;      0 to $FF (8 pixel steps = one full character column), we flip the double
;      buffer so the freshly-rebuilt back buffer becomes visible, advance the
;      map pointer one column, and reset fine_x to 7.
;   The back buffer is rebuilt incrementally (ROWS_PER_FRAME rows per frame by
;   build_back_slice) spread across the 8 inter-flip frames so no single frame
;   stalls waiting for a full 25-row redraw.
scroll_step
        jsr build_back_slice        ; spread the heavy work every frame; rebuild ROWS_PER_FRAME rows of back buffer

        dec fine_x                      ; decrement fine-scroll step counter (7..0, then wraps to $FF)
        bpl just_set_fine           ; fine_x still 0..6 -> set $D016; N=0 means still mid-char-step

        ; --- coarse frame: flip to freshly-built back buffer ----------
        ; fine_x went 0 -> $FF (bpl failed): 8 pixel-steps complete = one full character-column scrolled
        jsr flip_buffers                ; swap front/back: rebuilt back buffer becomes the new visible display
        jsr shift_color_ram         ; bring color RAM in line (sliced below*); shift color RAM left one column
        jsr inject_color_column     ; new right-edge color column; paint new rightmost color-RAM column

        jsr advance_map             ; consume one map column; advance zp_map and cache the new right-edge tiles

        lda #7                          ; fine_x reset value: restart 8-step fine-scroll count
        sta fine_x                      ; reset fine-scroll counter for the next character-width scroll cycle
        lda #2                          ; first row to rebuild = 2 (rows 0-1 are static HUD, skip them)
        sta build_row                   ; reset back-buffer rebuild-row index for the new char-step

just_set_fine
        rts                             ; return to IRQ; caller writes fine_x into $D016 bits 0-2

; =====================================================================
;  BUILD BACK SLICE
;  Build ROWS_PER_FRAME rows of the back buffer as:
;     back[row][0..38] = front[row][1..39]      (shift left one col)
;     back[row][39]    = map column tile for row (fresh right edge)
;  build_row tracks progress 0..24 across the char-step.
; =====================================================================
build_back_slice
        lda #ROWS_PER_FRAME             ; load per-frame row budget (e.g. 4 rows rebuilt per call)
        sta rpf_left                    ; store budget into countdown variable
bbs_loop
        ldx build_row                   ; load the next row index to rebuild (advances 0..24 over 8 frames)
        cpx #25                         ; have all 25 playfield rows been rebuilt for this char-step?
        bcs bbs_done                ; all 25 rows built this char-step; exit early (budget may still be > 0)

        ; zp_fsrc = front row base, zp_bdst = back row base
        jsr front_row_addr          ; uses X = build_row; sets zp_fsrc -> front-buffer row X (40 bytes)
        jsr back_row_addr           ; uses X = build_row; sets zp_bdst -> back-buffer row X (40 bytes)

        ; back[0..38] = front[1..39]
        ; Shift one character column left: front columns 1-39 become back columns 0-38
        ldx #0                          ; copy-loop index (0..38, one iteration per destination column)
bbs_col
        ldy bbs_srcidx,x            ; y = col+1  (1..39); look up source column (one to the right)
        lda (zp_fsrc),y                 ; read tile from front buffer at column col+1 of this row
        ldy bbs_dstidx,x            ; y = col    (0..38); look up destination column
        sta (zp_bdst),y                 ; write tile into back buffer at column col (shift left by 1)
        inx                             ; advance copy index
        cpx #39                         ; copied all 39 columns (0..38)?
        bne bbs_col                     ; no -> copy next column

        ; back[39] = cached right-edge tile for this row
        ; Column 39 (rightmost) gets the pre-cached new map tile, not a copy from the front buffer
        ldx build_row                   ; restore row index into X (bbs_col loop used X as copy counter)
        lda map_rightcol_cache,x        ; load pre-cached right-edge map tile for this row
        ldy #39                         ; destination column 39 (rightmost character column)
        sta (zp_bdst),y                 ; write new right-edge tile into back buffer column 39

        inc build_row                   ; advance to next row for the following slice call
        dec rpf_left                    ; decrement per-frame row budget
        bne bbs_loop                    ; budget not exhausted -> build another row this frame
bbs_done
        rts                             ; slice complete for this frame; return to scroll_step

rpf_left !byte ROWS_PER_FRAME          ; per-frame row budget countdown (decremented each iteration of bbs_loop)

; index tables for the column copy (avoids inx/iny juggling above)
bbs_srcidx !for c,0,38 { !byte c+1 }  ; 39-byte table: source column indices 1,2,...,39 (front col+1)
bbs_dstidx !for c,0,38 { !byte c }    ; 39-byte table: destination column indices 0,1,...,38 (back col)

; =====================================================================
;  FLIP BUFFERS: point VIC at the back buffer, swap front/back flag
; =====================================================================
flip_buffers
        lda front_is_a                  ; load front-buffer flag (non-zero = BUF_A is currently visible)
        beq fb_make_a_front         ; currently B front -> make A front; flag==0 means B is front now
        ; A is front -> show B
        ; BUF_A is currently front; switch VIC-II to display BUF_B ($3800) as the new front buffer
        lda #D18_B                      ; $D018 value routing VIC screen-RAM to BUF_B ($3800) and charset base
        sta VICMEM                      ; write to $D018 (VICMEM): VIC-II reads screen data from BUF_B next frame
        lda #0                          ; clear front_is_a: record that B is now the front buffer
        sta front_is_a                  ; BUF_B is now front (visible); BUF_A is now back (rebuilding)
        rts                             ; return; VIC displays BUF_B from next raster
fb_make_a_front
        ; BUF_B is currently front; switch VIC-II to display BUF_A ($0400) as the new front buffer
        lda #D18_A                      ; $D018 value routing VIC screen-RAM to BUF_A ($0400) and charset base
        sta VICMEM                      ; write to $D018: VIC-II reads screen data from BUF_A next frame
        lda #1                          ; set front_is_a: record that A is now the front buffer
        sta front_is_a                  ; BUF_A is now front (visible); BUF_B is now back (rebuilding)
        rts                             ; return

; =====================================================================
;  ADDRESS HELPERS
;  front_row_addr: zp_fsrc = (front buffer) + row*40, row in X
;  back_row_addr:  zp_bdst = (back  buffer) + row*40, row in X
; =====================================================================
front_row_addr
        lda front_is_a                  ; check which buffer is currently the front (visible) buffer
        bne fra_a                       ; non-zero -> BUF_A is front, take A path
        ; front = B
        ; BUF_B is the current front buffer; set zp_fsrc to BUF_B row X base address
        lda bufb_lo,x                   ; look up BUF_B row-X base address lo byte (pre-computed table)
        sta zp_fsrc                     ; store to ZP pointer lo byte
        lda bufb_hi,x                   ; look up BUF_B row-X base address hi byte
        sta zp_fsrc+1                   ; store to ZP pointer hi byte; (zp_fsrc) now -> BUF_B row X
        rts                             ; return with zp_fsrc set to front-buffer row X
fra_a
        ; BUF_A is the current front buffer; set zp_fsrc to BUF_A row X base address
        lda bufa_lo,x                   ; look up BUF_A row-X base address lo byte (pre-computed table)
        sta zp_fsrc                     ; store to ZP pointer lo byte
        lda bufa_hi,x                   ; look up BUF_A row-X base address hi byte
        sta zp_fsrc+1                   ; store to ZP pointer hi byte; (zp_fsrc) now -> BUF_A row X
        rts                             ; return with zp_fsrc set

back_row_addr
        lda front_is_a                  ; check which buffer is front; back is always the opposite buffer
        bne bra_back_is_b               ; non-zero -> A is front, so back = B
        ; front = B -> back = A
        ; BUF_B is front, so BUF_A is the hidden back buffer currently being rebuilt
        lda bufa_lo,x                   ; look up BUF_A row-X base address lo byte
        sta zp_bdst                     ; store to ZP destination pointer lo byte
        lda bufa_hi,x                   ; look up BUF_A row-X base address hi byte
        sta zp_bdst+1                   ; store to ZP destination pointer hi byte; (zp_bdst) -> BUF_A row X
        rts                             ; return with zp_bdst set to back-buffer row X
bra_back_is_b
        ; A is front, so BUF_B is the hidden back buffer currently being rebuilt
        lda bufb_lo,x                   ; look up BUF_B row-X base address lo byte
        sta zp_bdst                     ; store to ZP destination pointer lo byte
        lda bufb_hi,x                   ; look up BUF_B row-X base address hi byte
        sta zp_bdst+1                   ; store to ZP destination pointer hi byte; (zp_bdst) -> BUF_B row X
        rts                             ; return with zp_bdst set

; =====================================================================
;  COLOR RAM SHIFT  (sliced)  -- placeholder fixed-color this stage
;  For now color is uniform per tile, so we don't truly need to shift;
;  we keep a stub that maintains a static colored floor/sky split.
; =====================================================================
shift_color_ram
        rts                         ; (stage 1.5: color handled statically); stub: color-RAM shift not yet implemented

inject_color_column
        rts                             ; stub: right-edge color-column injection not yet implemented

; =====================================================================
;  MAP ADVANCE + RIGHT-COLUMN CACHE
;  We cache the 25 tiles of the column that will appear on the right edge
;  so build_back_slice can read them by row index cheaply.
; =====================================================================
advance_map
        ; advance zp_map by 25 (one column), wrap at map_end
        ; Each map column is 25 bytes (one tile per playfield row, 25 rows total)
        clc                             ; clear carry for 16-bit pointer addition
        lda zp_map                      ; load map pointer lo byte
        adc #25                         ; advance 25 bytes (one full column worth of tile data)
        sta zp_map                      ; store updated map pointer lo byte
        lda zp_map+1                    ; load map pointer hi byte
        adc #0                          ; propagate carry from lo byte addition
        sta zp_map+1                    ; store updated hi byte; zp_map now points to the next map column
        lda zp_map+1                    ; reload hi byte to compare against map_end boundary
        cmp #>map_end                   ; compare hi byte with map_end high byte
        bcc am_cache                    ; hi < map_end hi -> still inside map data, no wrap needed
        bne am_wrap                     ; hi > map_end hi -> past end of map, wrap now
        lda zp_map                      ; hi bytes equal: must also compare lo bytes for exact boundary
        cmp #<map_end                   ; compare lo byte with map_end low byte
        bcc am_cache                    ; lo < map_end lo -> still inside map, no wrap needed
am_wrap
        ; Map pointer has reached or passed map_end: wrap back to map_data for seamless level looping
        lda #<map_data                  ; low byte of map_data base address
        sta zp_map                      ; reset map pointer lo to start of map data
        lda #>map_data                  ; high byte of map_data base address
        sta zp_map+1                    ; reset map pointer hi to start of map data; map loops seamlessly
am_cache
        jsr cache_right_column          ; pre-cache the 25 tiles at current zp_map for right-edge use
        rts                             ; return; zp_map points to next column, right-column cache is fresh

cache_right_column
        ; Read 25 consecutive bytes from (zp_map) and write them into map_rightcol_cache[0..24]
        ldy #0                          ; Y = row index, start at row 0
crc_loop
        lda (zp_map),y                  ; load map tile for row Y from the current map column
        sty crc_tmp                     ; save Y to temp: LDX cannot index from Y directly
        ldx crc_tmp                     ; load row index into X for X-indexed store
        sta map_rightcol_cache,x        ; store tile into cache at index X (row Y's right-edge tile)
        iny                             ; advance to next row
        cpy #25                         ; all 25 rows cached?
        bne crc_loop                    ; no -> cache next row
        rts                             ; all 25 right-edge tiles cached; return
crc_tmp !byte 0                         ; one-byte temp: holds Y (row index) for transfer into X

map_rightcol_cache
        !fill 25, 0                     ; 25-byte cache: one tile per playfield row for the next right-edge column

; =====================================================================
;  INITIAL FILL: BUF_A from first 40 map columns; cache col 40
; =====================================================================
fill_front_from_map
        ; Write all 40 character columns of the initial screen into BUF_A from map_data,
        ; and populate color RAM with the static sky/floor color split.
        lda #<map_data                  ; low byte of map_data base address
        sta zp_map                      ; set map pointer lo = start of map data
        lda #>map_data                  ; high byte of map_data base address
        sta zp_map+1                    ; set map pointer hi = start of map data; zp_map -> column 0

        lda #0                          ; column counter initial value
        sta ff_col                      ; reset column loop counter to 0 (outer loop: 0..39)
ff_col_loop
        lda #0                          ; row counter initial value
        sta ff_row                      ; reset row loop counter to 0 (inner loop: 0..24)
ff_row_loop
        ldx ff_row                      ; load current row index into X for table lookups
        lda bufa_lo,x                   ; look up BUF_A row-X base address lo byte
        sta zp_dst                      ; store to destination pointer lo byte
        lda bufa_hi,x                   ; look up BUF_A row-X base address hi byte
        sta zp_dst+1                    ; store to destination pointer hi byte; (zp_dst) -> BUF_A row ff_row
        lda zp_dst                      ; load destination pointer lo byte
        clc                             ; clear carry before adding column offset
        adc ff_col                      ; add current column (0..39) to point at specific cell in this row
        sta zp_dst                      ; store updated pointer lo byte
        bcc ff_nohi                     ; no carry from lo addition -> hi byte unchanged, skip increment
        inc zp_dst+1                    ; carry: cross a 256-byte page boundary, increment hi byte
ff_nohi
        ldy ff_row                      ; Y = row index within the current map column (25 bytes/column)
        lda (zp_map),y                  ; load map tile for row ff_row from current column (zp_map + ff_row)
        ldy #0                          ; Y=0: column offset already baked into zp_dst, use offset 0
        sta (zp_dst),y                  ; write map tile into BUF_A at [row ff_row, col ff_col]

        ; color RAM: static sky/floor split
        ; Write the row's color value into color RAM using the crow_lo/crow_hi address tables
        ldx ff_row                      ; load row index for color-RAM address lookup
        lda crow_lo,x                   ; look up color-RAM row-X base address lo byte
        sta zp_dst                      ; reuse zp_dst for color-RAM destination pointer lo byte
        lda crow_hi,x                   ; look up color-RAM row-X base address hi byte
        sta zp_dst+1                    ; store color-RAM pointer hi byte; (zp_dst) -> color RAM row ff_row
        lda zp_dst                      ; load color-RAM pointer lo byte
        clc                             ; clear carry before column offset addition
        adc ff_col                      ; add column offset to reach specific color-RAM cell
        sta zp_dst                      ; store updated color pointer lo byte
        bcc ff_cnohi                    ; no carry -> hi byte unchanged
        inc zp_dst+1                    ; carry: increment hi byte across page boundary
ff_cnohi
        ldx ff_row                      ; reload row index (pointer arithmetic above may have used X)
        lda floor_color_tbl,x           ; look up color for this row from sky/floor split table
        ldy #0                          ; Y=0: offset already in zp_dst
        sta (zp_dst),y                  ; write color value into color RAM at [row ff_row, col ff_col]

        inc ff_row                      ; advance row counter
        lda ff_row                      ; load updated row counter
        cmp #25                         ; processed all 25 rows in this column?
        bne ff_row_loop                 ; no -> continue with next row in this column

        ; advance map pointer to the next column (25 bytes forward in map_data)
        clc                             ; clear carry for 16-bit addition
        lda zp_map                      ; load map pointer lo byte
        adc #25                         ; advance 25 bytes (one full map column)
        sta zp_map                      ; store updated map pointer lo byte
        lda zp_map+1                    ; load map pointer hi byte
        adc #0                          ; propagate carry from lo addition
        sta zp_map+1                    ; store updated map pointer hi byte; zp_map -> next column

        inc ff_col                      ; advance column counter
        lda ff_col                      ; load updated column counter
        cmp #40                         ; filled all 40 screen columns?
        bne ff_col_loop                 ; no -> continue with next column

        jsr cache_right_column      ; cache column 40 for first right edge; prime right-edge cache with column 40
        rts                             ; BUF_A fully initialized; color RAM set; scroll engine ready
ff_col !byte 0                          ; column loop counter (0..39) for initial map fill
ff_row !byte 0                          ; row loop counter (0..24) for initial map fill

; =====================================================================
;  COPY BUFFER A -> BUFFER B  (one-time at init so both start equal)
; =====================================================================
copy_a_to_b
        lda #<BUF_A                 ; low byte of BUF_A ($00); source = screen buffer A at $0400
        sta zp_fsrc                 ; store to ZP source pointer low byte
        lda #>BUF_A                 ; high byte of BUF_A ($04)
        sta zp_fsrc+1               ; store to ZP source pointer high byte; zp_fsrc now points at $0400
        lda #<BUF_B                 ; low byte of BUF_B ($00); dest = screen buffer B at $3800
        sta zp_bdst                 ; store to ZP dest pointer low byte
        lda #>BUF_B                 ; high byte of BUF_B ($38)
        sta zp_bdst+1               ; store to ZP dest pointer high byte; zp_bdst now points at $3800
        ldx #4                      ; 4 pages covers 1000 bytes (+pad)
        ldy #0                      ; byte index within current 256-byte page
cab_loop
        lda (zp_fsrc),y             ; read one byte from BUF_A at page-offset Y
        sta (zp_bdst),y             ; write same byte to BUF_B at same offset
        iny                         ; advance byte index within page
        bne cab_loop                ; inner loop: all 256 bytes of this page (Y wraps 255->0 on overflow)
        inc zp_fsrc+1               ; advance source pointer to next 256-byte page
        inc zp_bdst+1               ; advance dest pointer to next 256-byte page
        dex                         ; one fewer page remaining
        bne cab_loop                ; outer loop: copy all 4 pages (1024 bytes, covers 1000-byte screen + pad)
        rts                         ; done: BUF_A ($0400-$07FF) is now cloned into BUF_B ($3800-$3BFF)

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
        sta BUF_A+$3f8              ; write player-sprite pointer to BUF_A sprite table slot 0 ($07F8)
        sta BUF_B+$3f8              ; same in BUF_B slot 0 ($3BF8); both buffers must agree so buffer flip keeps sprite
        ; --- sprites 1..7 all point at the shared mux shape, both buffers ---
        lda #209                    ; ptr 209 = $3440/64; the shared mux_shape used by all non-player sprites
        ldx #1                      ; start at slot 1 (slot 0 is the player)
ip_loop
        sta BUF_A+$3f8,x            ; set sprite-pointer byte in BUF_A table for slot X ($07F9-$07FF)
        sta BUF_B+$3f8,x            ; same in BUF_B table ($3BF9-$3BFF)
        inx                         ; next sprite slot
        cpx #8                      ; have we set all 8 sprite-pointer bytes?
        bne ip_loop                 ; no: continue

        lda #%11111111              ; enable all 8 sprites
        sta SPENA                   ; $D015 SPENA: all 8 hardware sprites active
        lda #%00000001              ; only bit 0 set = only sprite 0 is multicolor
        sta SPMC                    ; $D01C: sprite 0 in multicolor mode (3-color ship); sprites 1-7 hi-res
        ; --- no expansion, sprites in front of background ---
        lda #0                      ; clear all bits
        sta XXPAND                  ; $D01D: no horizontal 2x expansion on any sprite
        sta YXPAND                  ; $D017: no vertical 2x expansion on any sprite
        sta SPBGPR                  ; $D01B: all sprites drawn in front of background (priority 0)

        ; --- colors (contrast against blue bg) ---
        lda #1               ; hull = white
        sta SP0COL                  ; $D027: player ship main (bit-pair 10) = white (color 1)
        lda #7               ; shared MC0 = yellow (engine)
        sta SPMC0                   ; $D025: shared multicolor 0 (bit-pair 01) = yellow (7); engine glow
        lda #2               ; shared MC1 = red (cockpit)
        sta SPMC1                   ; $D026: shared multicolor 1 (bit-pair 11) = red (2); cockpit detail
        lda #7               ; sprite 1 default color (yellow)
        sta SP1COL                  ; $D028: sprite 1 (first mux hardware slot) default color = yellow

        ; --- CIA1 data direction for keyboard scan (defensive) ---
        lda #$ff                    ; all bits = output direction
        sta $dc02                   ; CIA1 port-A DDR: drive all row lines as outputs (select keyboard row)
        lda #$00                    ; all bits = input direction
        sta $dc03                   ; CIA1 port-B DDR: read all column lines as inputs (read key state)

        ; --- start position comes from player_x/player_y vars ---
        jsr write_player_sprite     ; push initial player_x/player_y values to VIC sprite-0 X/Y registers
        rts

; =====================================================================
;  COLORS
; =====================================================================
set_colors
        lda #6                      ; color 6 = blue
        sta BGCOL0                  ; $D021: background color 0 = blue (sky fill; char bit-pair 00 = transparent/bg)
        lda #14                     ; color 14 = light blue
        sta BGCOL1                  ; $D022: multicolor BG 1 = light blue (sky detail; char bit-pair 01)
        lda #11                     ; color 11 = dark gray/brown
        sta BGCOL2                  ; $D023: multicolor BG 2 = dark gray (terrain detail; char bit-pair 10)
        rts

; =====================================================================
;  CHARSET (same 4 tiles as stage 1)
; =====================================================================
build_charset
        lda #<CHARSET               ; low byte of charset RAM destination
        sta zp_dst                  ; store to ZP dest pointer low
        lda #>CHARSET               ; high byte of charset RAM destination
        sta zp_dst+1                ; store to ZP dest pointer high; zp_dst -> CHARSET base
        ldx #8                      ; 8 pages = 2048 bytes = 256 characters × 8 rows each
        ldy #0                      ; byte index within current page
bc_clear
        lda #0                      ; zero = all pixels off = blank row
        sta (zp_dst),y              ; zero this charset byte
        iny                         ; next byte within page
        bne bc_clear                ; inner loop: clear 256 bytes
        inc zp_dst+1                ; advance destination to next 256-byte page
        dex                         ; one fewer page remaining
        bne bc_clear                ; outer loop: clear all 8 pages of charset RAM

; --- tile 1: sparse star/detail dot (screen code 1) ---
        lda #%00110000              ; two adjacent pixels at columns 2-3 (from MSB)
        sta CHARSET + 1*8 + 3       ; tile 1, row 3 only: small 2-pixel dot near vertical center

        ldx #0                      ; row index 0..7
bc_block
; --- tile 2: solid block (platforms, floor, ceiling; screen code 2) ---
        lda #%11111111              ; all 8 pixels lit = fully solid row
        sta CHARSET + 2*8, x        ; tile 2 row X = solid; loops over all 8 rows -> filled rectangle
        inx                         ; next row
        cpx #8                      ; done all 8 rows of tile 2?
        bne bc_block                ; no: continue

; --- tile 3: dithered-top + solid-bottom terrain (screen code 3) ---
        lda #%10101010              ; alternating pixels: columns 0,2,4,6 lit = coarse checkerboard row
        sta CHARSET + 3*8 + 0       ; tile 3, row 0: sparse dithered surface (rough ground top)
        sta CHARSET + 3*8 + 1       ; tile 3, row 1: sparse dithered
        sta CHARSET + 3*8 + 2       ; tile 3, row 2: sparse dithered
        sta CHARSET + 3*8 + 3       ; tile 3, row 3: sparse dithered (4 rows of rough ground texture)
        lda #%11111111              ; all 8 pixels lit = solid
        sta CHARSET + 3*8 + 4       ; tile 3, row 4: solid ground body begins
        sta CHARSET + 3*8 + 5       ; tile 3, row 5: solid
        sta CHARSET + 3*8 + 6       ; tile 3, row 6: solid
        sta CHARSET + 3*8 + 7       ; tile 3, row 7: solid bottom (tile = rough surface + solid base)

        ; --- digit glyphs 0-9 at screen codes 16..25 ---
        ldx #0                      ; byte index into digit_glyphs table (10 glyphs × 8 bytes = 80 bytes)
bc_dig
        lda digit_glyphs,x          ; load one pixel row of a digit bitmap
        sta CHARSET + DIGIT_BASE*8, x ; write into charset at code DIGIT_BASE (16) onward
        inx                         ; next byte
        cpx #80                     ; copied all 80 bytes (10 digits × 8 rows)?
        bne bc_dig                  ; no: continue
        ; --- letter glyphs at screen codes 26.. (S c o r e h i p s l f t :) ---
        ldx #0                      ; byte index into letter_glyphs table (13 glyphs × 8 bytes = 104 bytes)
bc_let
        lda letter_glyphs,x         ; load one pixel row of a letter bitmap
        sta CHARSET + 26*8, x       ; write into charset at code 26 onward (S=26 … :=38)
        inx                         ; next byte
        cpx #104                    ; copied all 104 bytes (13 glyphs × 8 rows)?
        bne bc_let                  ; no: continue
        rts

; sid_init: master volume max, all gates off, clear sfx timers
sid_init
        lda #$0f                    ; volume = 15 (maximum), no filter routing
        sta $d418               ; volume 15, no filter
        lda #0                      ; 0 = waveform disabled, gate bit cleared = silence
        sta $d404               ; V1 control (gate off)
        sta $d40b               ; V2 control
        sta $d412               ; V3 control
        sta sfxTimer+0              ; voice 1 sfx frame-countdown = 0 (idle, no effect playing)
        sta sfxTimer+1              ; voice 2 sfx frame-countdown = 0 (idle)
        sta sfxTimer+2              ; voice 3 sfx frame-countdown = 0 (idle)
        rts

; sound_voice: advance one voice (X = 0,1,2). Sweep freq, write SID, gate
; off when the timer expires. Uses $fd/$fe as the SID voice pointer.
sound_voice
        lda sfxTimer,x              ; load frame-countdown for voice X (0 = idle)
        bne sv_active               ; non-zero = effect still in progress
        rts                     ; idle
sv_active
        lda sidbase_lo,x            ; SID voice base address low byte: V1=$00, V2=$07, V3=$0E
        sta $fd                     ; ZP indirect pointer low = voice base offset
        lda #$d4                    ; SID page is always $D4xx
        sta $fe                     ; ZP indirect pointer high = $D4; ($fe,$fd) now addresses voice registers
        clc                         ; clear carry before 16-bit add
        lda sfxFreqLo,x             ; current frequency register low byte
        adc sfxSweepLo,x            ; add per-frame sweep delta low byte (signed 16-bit add, low half)
        sta sfxFreqLo,x             ; save updated frequency low
        ldy #0                      ; register offset 0 = frequency low within voice block
        sta ($fd),y             ; SID freq lo
        lda sfxFreqHi,x             ; current frequency register high byte
        adc sfxSweepHi,x            ; add per-frame sweep delta high byte (carry from low half)
        sta sfxFreqHi,x             ; save updated frequency high
        ldy #1                      ; register offset 1 = frequency high within voice block
        sta ($fd),y             ; SID freq hi
        dec sfxTimer,x              ; decrement frame countdown
        bne sv_ret                  ; not yet expired: done for this frame
        lda sfxRelease,x        ; timer hit 0 -> gate off (release)
        ldy #4                      ; register offset 4 = control register within voice block
        sta ($fd),y                 ; write control byte with gate cleared -> starts ADSR release phase
sv_ret
        rts

; sound_update: advance all three voices (called once per frame)
sound_update
        ldx #0                      ; voice index 0 = V1 (laser / fire channel)
        jsr sound_voice             ; sweep V1 frequency and decrement its timer
        ldx #1                      ; voice index 1 = V2 (explosion noise channel)
        jsr sound_voice             ; sweep V2
        ldx #2                      ; voice index 2 = V3 (hit / boss channel)
        jsr sound_voice             ; sweep V3
        rts

; sfx_fire: short laser "pew" on V1
; Sawtooth wave; starts at $2800 (~601 Hz, ~D5); sweeps down -$0300/frame over 6 frames to ~$1600 (~330 Hz)
sfx_fire
        lda #$09                    ; high nibble=0 (attack instant), low nibble=9 (decay medium)
        sta $d405               ; AD: attack 0, decay 9
        lda #$00                    ; sustain=0 (drops to zero immediately), release=0 (instant)
        sta $d406               ; SR: sustain 0, release 0
        lda #$00                    ; frequency low byte = 0
        sta sfxFreqLo+0             ; save starting V1 freq low for sweep engine
        sta $d400                   ; SID V1 freq lo = 0
        lda #$28                    ; frequency high byte = $28; starting freq = $2800 ≈ 601 Hz (~D5)
        sta sfxFreqHi+0             ; save starting V1 freq high
        sta $d401               ; start freq $2800
        lda #$00                    ; sweep low byte = 0
        sta sfxSweepLo+0            ; no low-byte sweep component
        lda #$fd                    ; sweep high byte = $FD = -3 signed; 16-bit sweep value = -$0300 = -768/frame
        sta sfxSweepHi+0        ; sweep -$0300/frame
        lda #$20                    ; $20 = sawtooth waveform bit, gate bit=0 = note-off control byte
        sta sfxRelease+0        ; saw, gate off
        lda #$21                    ; $20 (sawtooth) | $01 (gate on) = start sawtooth note
        sta $d404               ; saw + gate on
        lda #6                      ; duration: 6 frames (~120 ms at 50 Hz PAL)
        sta sfxTimer+0              ; set V1 countdown; sound_voice will sweep freq and gate off at expiry
        rts

; sfx_explosion: noise "boom" on V2
; Noise waveform; starts at $1800 (~361 Hz); sweeps down -$0100/frame over 16 frames to ~$0800 (~120 Hz)
sfx_explosion
        lda #$0a                    ; attack=0 (instant), decay=10 (slower than fire = longer rumble)
        sta $d40c               ; V2 AD
        lda #$00                    ; sustain=0, release=0
        sta $d40d               ; V2 SR
        lda #$00                    ; frequency low byte = 0
        sta sfxFreqLo+1             ; save starting V2 freq low
        sta $d407                   ; SID V2 freq lo = 0
        lda #$18                    ; frequency high byte = $18; starting freq = $1800 ≈ 361 Hz
        sta sfxFreqHi+1             ; save starting V2 freq high
        sta $d408               ; start freq $1800
        lda #$00                    ; sweep low byte = 0
        sta sfxSweepLo+1            ; no low-byte sweep component
        lda #$ff                    ; sweep high = $FF = -1 signed; 16-bit sweep = -$0100 = -256/frame
        sta sfxSweepHi+1        ; sweep -$0100/frame
        lda #$80                    ; $80 = noise waveform bit, gate=0 = note-off control byte
        sta sfxRelease+1        ; noise, gate off
        lda #$81                    ; $80 (noise) | $01 (gate on) = start noise burst
        sta $d40b               ; noise + gate on
        lda #16                     ; duration: 16 frames (~320 ms) = sustained rumble
        sta sfxTimer+1              ; set V2 countdown
        rts

; sfx_hit: damage "thud" on V3
; Pulse wave ~50% duty; starts at $0A00 (~150 Hz); sweeps down -$0040/frame over 20 frames to ~$0500 (~75 Hz)
sfx_hit
        lda #$0a                    ; attack=0 (instant), decay=10
        sta $d413               ; V3 AD
        lda #$00                    ; sustain=0, release=0
        sta $d414               ; V3 SR
        lda #$00                    ; pulse width low byte = 0
        sta $d410               ; pulse width lo
        lda #$08                    ; pulse width high = $08; pulse width = $0800/4096 ≈ 50% duty cycle
        sta $d411               ; pulse width hi (~50%)
        lda #$00                    ; frequency low byte = 0
        sta sfxFreqLo+2             ; save starting V3 freq low
        sta $d40e                   ; SID V3 freq lo = 0
        lda #$0a                    ; frequency high = $0A; starting freq = $0A00 ≈ 150 Hz (low thud)
        sta sfxFreqHi+2             ; save starting V3 freq high
        sta $d40f               ; start freq $0a00
        lda #$c0                    ; sweep low = $C0 = -64 unsigned low byte; contributes to -$0040 combined
        sta sfxSweepLo+2            ; sweep low component
        lda #$ff                    ; sweep high = $FF = -1 signed; combined 16-bit = $FFC0 = -64 = -$0040/frame
        sta sfxSweepHi+2        ; sweep -$0040/frame
        lda #$40                    ; $40 = pulse waveform bit, gate=0 = note-off control byte
        sta sfxRelease+2        ; pulse, gate off
        lda #$41                    ; $40 (pulse) | $01 (gate on) = start pulse note
        sta $d412               ; pulse + gate on
        lda #20                     ; duration: 20 frames (~400 ms)
        sta sfxTimer+2              ; set V3 countdown
        rts

; sfx_boss: ominous rising warning sting on V3
; Pulse wave; starts at $0400 (~60 Hz); sweeps UP +$0030/frame over 30 frames to ~$09A0 (~145 Hz)
sfx_boss
        lda #$08                    ; attack=0, decay=8 (medium fade)
        sta $d413               ; V3 AD
        lda #$00                    ; sustain=0, release=0
        sta $d414               ; V3 SR
        lda #$00                    ; pulse width low = 0
        sta $d410                   ; V3 pulse width lo
        lda #$08                    ; pulse width high = $08; 50% duty cycle
        sta $d411               ; pulse width ~50%
        lda #$00                    ; frequency low byte = 0
        sta sfxFreqLo+2             ; save starting V3 freq low
        sta $d40e                   ; SID V3 freq lo = 0
        lda #$04                    ; frequency high = $04; starting freq = $0400 ≈ 60 Hz (very low bass)
        sta sfxFreqHi+2             ; save starting V3 freq high
        sta $d40f               ; start freq $0400 (low)
        lda #$30                    ; sweep low = $30 = +48; low byte of +$0030 rise per frame
        sta sfxSweepLo+2            ; sweep low: +$30/frame
        lda #$00                    ; sweep high = 0; combined 16-bit sweep = +$0030 = +48/frame (rising pitch)
        sta sfxSweepHi+2        ; sweep +$0030/frame (rising)
        lda #$40                    ; pulse waveform bit, gate=0 = note-off value for release
        sta sfxRelease+2            ; pulse wave; gate-off control byte stored for timer expiry
        lda #$41                    ; $40 (pulse) | $01 (gate on) = start note
        sta $d412               ; pulse + gate on
        lda #30                     ; duration: 30 frames (~600 ms) = distinctive boss-warning sting
        sta sfxTimer+2              ; set V3 countdown
        rts

; =====================================================================
;  ROW ADDRESS TABLES
; =====================================================================
bufa_lo  !for row,0,24 { !byte <(BUF_A + row*40) }  ; 25 low bytes of BUF_A row start addresses (rows 0-24, 40 cols/row)
bufa_hi  !for row,0,24 { !byte >(BUF_A + row*40) }  ; 25 high bytes of BUF_A row start addresses
bufb_lo  !for row,0,24 { !byte <(BUF_B + row*40) }  ; 25 low bytes of BUF_B row start addresses (rows 0-24)
bufb_hi  !for row,0,24 { !byte >(BUF_B + row*40) }  ; 25 high bytes of BUF_B row start addresses
crow_lo  !for row,0,24 { !byte <(COLORRAM + row*40) }  ; 25 low bytes of color RAM row addresses ($D800 + row*40)
crow_hi  !for row,0,24 { !byte >(COLORRAM + row*40) }  ; 25 high bytes of color RAM row addresses

; static color per row: sky rows light, floor rows brown-ish
floor_color_tbl
        !for row,0,24 {             ; emit 25 color bytes, one per screen row 0-24
            !if row >= 23 { !byte 8 } else {  ; rows 23-24: color 8 = orange (solid floor rows)
                !if row = 22 { !byte 7 } else { !byte 14 }  ; row 22: color 7 = yellow (floor cap/ledge); rows 0-21: color 14 = light blue (sky)
            }
        }

digit_glyphs
; 10 digit glyphs (screen codes 16-25), 8 bytes each = 80 bytes total
; each byte is one 8-pixel-wide scanline of the glyph bitmap (MSB = leftmost pixel)
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
; 13 letter/symbol glyphs (codes 26-38), 8 bytes each = 104 bytes; used for HUD "Score:" and "Ships left:" labels
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
        !for col, 0, 119 {          ; 120 columns total; each column = 25 bytes; total = 3000 bytes at $2800-$3377
            !for r, 0, 21 {         ; rows 0-21: sky area (22 bytes per column)
                !if (((col*7 + r*13) & 31) = 0) { !byte 1 } else { !byte 0 }  ; hash=(col*7+r*13)&31 == 0 -> tile 1 (sparse star/dot), else tile 0 (blank sky)
            }
            !if ((col & 7) = 0) { !byte 2 } else { !byte 0 }  ; row 22: every 8th column gets tile 2 (solid block cap = ceiling strut), else blank
            !byte 3                 ; row 23: tile 3 (dithered-top + solid-body = ground tile, upper ground row)
            !byte 3                 ; row 24: tile 3 (ground tile, lower ground row; floor is 2 chars tall)
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
        !byte $00,$00,$00   ; row 0  (blank - top padding above ship silhouette)
        !byte $00,$00,$00   ; row 1  (blank)
        !byte $00,$00,$00   ; row 2  (blank)
        !byte $00,$00,$00   ; row 3  (blank)
        !byte $00,$00,$00   ; row 4  (blank)
        !byte $a0,$00,$00   ; row 5  ($a0=10100000): tip of upper wing; bit-pair 10=white, one pixel
        !byte $aa,$00,$00   ; row 6  ($aa=10101010): upper wing broadens; alternating white bit-pairs
        !byte $6a,$a0,$00   ; row 7  ($6a=01101010): yellow (01) mixed with white (10); wing + body start
        !byte $6a,$ea,$00   ; row 8  ($ea=11101010): red cockpit rear (11) appears
        !byte $6a,$fa,$a8   ; row 9  ($fa=11111010,$a8=10101000): cockpit widens, nose tip begins
        !byte $6a,$fa,$aa   ; row 10 ($aa=10101010 tail): full mid-body row = thickest point of ship
        !byte $6a,$fa,$a8   ; row 11 (mirror of row 9: ship is vertically symmetric about row 10)
        !byte $6a,$ea,$00   ; row 12 (mirror of row 8)
        !byte $6a,$a0,$00   ; row 13 (mirror of row 7)
        !byte $aa,$00,$00   ; row 14 (mirror of row 6: lower wing)
        !byte $a0,$00,$00   ; row 15 (mirror of row 5: lower wing tip)
        !byte $00,$00,$00   ; row 16 (blank)
        !byte $00,$00,$00   ; row 17 (blank)
        !byte $00,$00,$00   ; row 18 (blank)
        !byte $00,$00,$00   ; row 19 (blank)
        !byte $00,$00,$00   ; row 20 (blank - bottom padding; 21 rows × 3 bytes = 63 + 1 pad = 64)
        !byte $00           ; pad to 64 bytes

* = $3440
mux_shape                    ; shared shape for all multiplexed sprites (ptr 209)
        !fill 8*3, 0         ; rows 0-7 blank (24 zero bytes: top of 24×21 sprite empty)
        !byte $00,$7e,$00    ; row 8   (0111 1110): oval top edge; 6 center pixels lit
        !byte $00,$ff,$00    ; row 9   (1111 1111): full-width body; all 8 center pixels lit
        !byte $00,$ff,$00    ; row 10  (1111 1111): full-width body center row
        !byte $00,$ff,$00    ; row 11  (1111 1111): full-width body
        !byte $00,$7e,$00    ; row 12  (0111 1110): oval bottom edge; 6 center pixels lit
        !fill 8*3, 0         ; rows 13-20 blank (24 zero bytes: bottom of sprite empty)
        !byte $00            ; pad byte: 24 + 5×3 + 24 + 1 = 64 bytes total

; =====================================================================
;  VIRTUAL SPRITE TABLE + MUX STATE  (free space $3480-$37FF, below BUF_B $3800)
; =====================================================================
* = $3480
vsXlo    !fill 15,0       ; virtual sprite X low (9-bit X = vsXhi:vsXlo)
vsXhi    !fill 15,0       ; virtual sprite X bit 8 (0 or 1); extends range to 512 pixels wide
vsY      !fill 15,255     ; virtual sprite Y; 255 = off-screen/inactive (sorts to end so mux skips it)
vsColor  !fill 15,0       ; per-slot sprite color written to $D027-$D02E by mux IRQ
vsActive !fill 15,0       ; slot liveness: 0 = free/available to spawn into, 1 = live
vsVY     !fill 15,0       ; signed vertical velocity in pixels/frame; applied by sine/zigzag patterns
vsPattern !fill 15,0       ; movement pattern: 0=straight horizontal, 1=sine wave, 2=zig-zag
vsPhase   !fill 15,0       ; current index (0-63) into sineTable; advances each frame for pattern 1
vsState   !fill 15,0       ; per-slot FSM: 0=alive (normal), 1=exploding (animation playing)
vsExplodeTimer !fill 15,0  ; frames remaining in explosion animation; slot freed when this hits 0
vsBaseY   !fill 15,0       ; center Y for sine oscillation; vsY oscillates above/below this value
spawnTimer !byte 30         ; frames until next enemy is spawned; decrements to 0 then reloads
spawnIndex !byte 0          ; index (0-7) into waveY/wavePattern for next spawn; cycles mod waveN
enemyFireTimer !byte 30     ; frames until next enemy fires a bullet; counts down to 0
enemyFireIndex !byte 6      ; virtual-sprite slot that fires next; starts at 6 (first enemy slot)
ef_scan        !byte 0      ; scan counter used when searching active enemy slots for a shooter
chDlo      !byte 0        ; check_hits scratch: dX low byte
chDhi      !byte 0        ; check_hits scratch: dX high byte
waveY       !byte 90,120,150,100,140,95,170,110   ; initial Y screen positions for 8 wave enemies
wavePattern !byte 0,1,2,1,0,2,1,0    ; straight/sine/zigzag mix
waveN = 8                   ; number of entries in wave tables (constant, not stored in RAM)
sineTable
; 64-entry signed sine LUT, one full period; range approx $F0 (-16) to $10 (+16) pixels
        !byte $00,$02,$03,$05,$06,$08,$09,$0a,$0b,$0c,$0d,$0e,$0f,$0f,$10,$10  ; phase  0-15: rising 0 -> +16 (quarter-wave up)
        !byte $10,$10,$10,$0f,$0f,$0e,$0d,$0c,$0b,$0a,$09,$08,$06,$05,$03,$02  ; phase 16-31: descending +16 -> 0 (quarter-wave down)
        !byte $00,$fe,$fd,$fb,$fa,$f8,$f7,$f6,$f5,$f4,$f3,$f2,$f1,$f1,$f0,$f0  ; phase 32-47: descending 0 -> -16 (quarter-wave below zero)
        !byte $f0,$f0,$f0,$f1,$f1,$f2,$f3,$f4,$f5,$f6,$f7,$f8,$fa,$fb,$fd,$fe  ; phase 48-63: rising -16 -> 0 (quarter-wave back to zero)
sortIdx  !byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14   ; slot order by Y (persists, re-sorted)
; schedule double buffer: buffer 0 = entries 0..14, buffer 1 = entries 15..29
schY     !fill 30,0         ; double-buffered Y values for mux IRQ schedule (2 halves × 15 entries)
schXlo   !fill 30,0         ; double-buffered X low bytes for schedule
schXhi   !fill 30,0         ; double-buffered X MSBs (bit 8) for schedule
schColor !fill 30,0         ; double-buffered color bytes for schedule
schCount !byte 0,0        ; [buffer] live count
schFront !byte 0          ; buffer the IRQ reads (0/1)
; multiplex IRQ state
muxIdx   !byte 0          ; current schedule array index (already buffer-offset)
muxEnd   !byte 0          ; stop index (base+count)
muxHW    !byte 1          ; next hardware sprite (1..7, round robin)
; bullet fire cooldown
fireCool !byte 0            ; player fire cooldown; 0 = may fire; set to non-zero after each shot
; sort/build scratch
sortKey  !byte 0            ; temporary Y value held during insertion-sort inner loop
sortJ    !byte 0            ; inner-loop index during insertion sort of sortIdx[]
tmpSlot  !byte 0            ; temporary slot number during sort swap operation
schBack  !byte 0            ; back buffer index (0 or 1); the buffer being written while IRQ reads front
schBackBase !byte 0         ; base array offset into sch* arrays for back buffer (0 or 15)
bsBase   !byte 0            ; build_schedule: starting write pointer this frame (to count emitted entries)
ss_x     !byte 1            ; scratch variable used inside schedule-build loop
; bit masks indexed by hardware sprite number 0..7
msbset   !byte $01,$02,$04,$08,$10,$20,$40,$80   ; bit masks to SET bit N of $D010 (sprite X MSB register)
msbclr   !byte $fe,$fd,$fb,$f7,$ef,$df,$bf,$7f   ; bit masks to CLEAR bit N of $D010 (inverted msbset)
playerState !byte 0        ; 0 alive, 1 exploding, 2 invulnerable
playerTimer !byte 0         ; countdown: explosion animation duration or post-death invulnerability frames
lives       !byte 3         ; remaining lives; game over when this reaches 0
flashTimer  !byte 0        ; border flash countdown (game over)
score       !byte 0,0,0   ; 3-byte BCD, low byte first (6 digits)
killCount   !byte 0         ; total enemies destroyed; boss encounter triggers when this reaches 5
bossState   !byte 0         ; boss FSM: 0=INACTIVE, 1=ENTER (flying in from right), 2=FIGHT, 3=DYING
bossHP      !byte 0         ; boss hit points remaining; starts at 5 (one per boss sprite hit)
bossXlo     !byte 0         ; boss cluster X position low byte (9-bit coordinate)
bossXhi     !byte 0         ; boss cluster X position bit 8 (MSB for screen-width overflow)
bossY       !byte 0         ; boss cluster center Y; all 5 sprite pieces are offset from this
bossYCenter !byte 0         ; vertical center for boss bob oscillation (sine motion target)
bossPhase   !byte 0         ; sineTable index for boss vertical bobbing; advances each frame during FIGHT
bossFireTimer !byte 0       ; countdown between boss bullet volleys; reloaded after each salvo
bossFlash   !byte 0         ; hit-flash counter; non-zero causes boss sprites to show damage color
bossDeathTimer !byte 0      ; death-sequence animation countdown; pieces explode in turn as this falls
bossOffY    !byte $e8,$f4,$00,$0c,$18   ; -24,-12,0,12,24 (signed)
sfxTimer    !fill 3,0          ; frames remaining per voice (0 = idle)
sfxFreqLo   !fill 3,0          ; current SID freq-register low byte per voice; updated by sound_voice
sfxFreqHi   !fill 3,0          ; current SID freq-register high byte per voice
sfxSweepLo  !fill 3,0          ; signed 16-bit per-frame freq delta
sfxSweepHi  !fill 3,0          ; sweep high byte; combined with sfxSweepLo forms signed 16-bit delta/frame
sfxRelease  !fill 3,0          ; control-reg value with gate cleared (note-off)
sidbase_lo  !byte $00,$07,$0e  ; SID voice base low bytes (high byte $d4)
