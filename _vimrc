"source $VIMRUNTIME/vimrc_example.vim
source $VIMRUNTIME/mswin.vim

colorscheme koehler
let mapleader = "\<Space>"

set nu
set hidden
set nobackup
set tabstop=2
set expandtab
set noundofile
set nocompatible
set shiftwidth=2
set nowritebackup

set guifont=Consolas:h14
set guioptions-=T

set runtimepath^=$VIM_HOME/vimfiles/bundle/*

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

nnoremap <Leader>p :CtrlP<CR>
map <Leader> <Plug>(easymotion-prefix)

filetype plugin indent on
syntax on
