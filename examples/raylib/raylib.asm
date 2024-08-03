#WIDTH 800
#HEIGHT 600
#TARGET_FPS 60

#TEXT_COLOR 0xFFFFFFFF
#BACKGROUND_COLOR 0xFF181818

#TITLE "hello"
#TEXT "hello from raylib"

_start:
    push @TARGET_FPS
    native set_target_fps

    push 800
    push 600
    push @TITLE
    native init_window

.loop:
    native begin_drawing

    push @BACKGROUND_COLOR
    native clear_background

    push @TEXT

    native get_screen_width
    push 2
    idiv

    push 2
    idiv

    native get_screen_height
    push 2
    idiv

    push 40
    push @TEXT_COLOR

    native draw_text

    native end_drawing

    native window_should_close
    not

    jmp_if .loop
