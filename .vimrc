"git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim

colorscheme koehler
let mapleader = "\<Space>"

set nu
set noeb
set mouse=
set hidden
set expandtab
set tabstop=2
set nocompatible
set shiftwidth=2
set backspace=indent,eol,start

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

filetype off
set rtp+=~/.vim/bundle/Vundle.vim
call vundle#begin()
Plugin 'VundleVim/Vundle.vim'

Plugin 'kien/ctrlp.vim'
nnoremap <Leader>p :CtrlP<CR>

Plugin 'scrooloose/nerdtree'
nnoremap <Leader>o :NERDTreeToggle<CR>

Plugin 'easymotion/vim-easymotion'
map <Leader> <Plug>(easymotion-prefix)
call vundle#end()
filetype plugin indent on

syntax on
