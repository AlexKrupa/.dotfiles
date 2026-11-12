# Colors for bold, underline, and standout text in less. man pages use bold and underline.
set -gx LESS_TERMCAP_md (set_color --bold 0280A5)
set -gx LESS_TERMCAP_me (set_color normal)
set -gx LESS_TERMCAP_us (set_color --underline 5BA502)
set -gx LESS_TERMCAP_ue (set_color normal)
set -gx LESS_TERMCAP_so (set_color --reverse F0CB02)
set -gx LESS_TERMCAP_se (set_color normal)
