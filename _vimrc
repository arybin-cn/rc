"set im!
set guioptions-=T
set guifont=Consolas:h14
set clipboard+=unnamed

source $VIMRUNTIME/vimrc_example.vim
"source $VIMRUNTIME/mswin.vim
behave mswin

set diffexpr=MyDiff()
function MyDiff()
  let opt = '-a --binary '
  if &diffopt =~ 'icase' | let opt = opt . '-i ' | endif
  if &diffopt =~ 'iwhite' | let opt = opt . '-b ' | endif
  let arg1 = v:fname_in
  if arg1 =~ ' ' | let arg1 = '"' . arg1 . '"' | endif
  let arg2 = v:fname_new
  if arg2 =~ ' ' | let arg2 = '"' . arg2 . '"' | endif
  let arg3 = v:fname_out
  if arg3 =~ ' ' | let arg3 = '"' . arg3 . '"' | endif
  if $VIMRUNTIME =~ ' '
    if &sh =~ '\<cmd'
      if empty(&shellxquote)
        let l:shxq_sav = ''
        set shellxquote&
      endif
      let cmd = '"' . $VIMRUNTIME . '\diff"'
    else
      let cmd = substitute($VIMRUNTIME, ' ', '" ', '') . '\diff"'
    endif
  else
    let cmd = $VIMRUNTIME . '\diff'
  endif
  silent execute '!' . cmd . ' ' . opt . arg1 . ' ' . arg2 . ' > ' . arg3
  if exists('l:shxq_sav')
    let &shellxquote=l:shxq_sav
  endif
endfunction

colorscheme koehler
let mapleader = "\<Space>"

set nu
set hidden
set nobackup
set tabstop=2
set expandtab
set nocompatible
set noundofile
set shiftwidth=2
set nowritebackup
set fileencodings=utf-8,gbk

cnoremap <C-N> <DOWN>
cnoremap <C-P> <UP>

nnoremap } :tabn<CR>
nnoremap { :tabp<CR>
nnoremap <Leader><Leader> :
nnoremap <Leader>c @:

inoremap FF <ESC>mfgg=G`fzz
inoremap JK <ESC>:wq<CR>
inoremap jk <ESC>:w<CR>
inoremap jl <ESC>A

imap j; jl;jk
imap jv ""jki
imap jb ''jki
imap jt <>jki
imap jg []jki
imap jf {}jki
imap jd ()jki

imap jwd <ESC>ciw(<C-R>")
imap jWd <ESC>ciW(<C-R>")
imap jc jk@:

filetype plugin indent on
syntax on
