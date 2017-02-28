let s:Dict = vital#gina#import('Data.Dict')
let s:Group = vital#gina#import('Vim.Buffer.Group')
let s:Opener = vital#gina#import('Vim.Buffer.Opener')

let s:SCHEME = gina#command#scheme(expand('<sfile>'))


function! gina#command#blame#call(range, args, mods) abort
  call gina#process#register(s:SCHEME, 1)
  try
    call s:call(a:range, a:args, a:mods)
  finally
    call gina#process#unregister(s:SCHEME, 1)
  endtry
endfunction


" Private --------------------------------------------------------------------
function! s:build_args(git, args) abort
  let args = a:args.clone()
  let args.params.groups = [
        \ args.pop('--group1', 'blame-body'),
        \ args.pop('--group2', 'blame-navi'),
        \]
  let args.params.opener = args.pop('--opener', 'edit')
  let args.params.line = args.pop('--line', v:null)
  let args.params.col = args.pop('--col', v:null)
  let args.params.width = args.pop('--width', 30)

  call gina#core#args#extend_treeish(a:git, args, args.pop(1))
  if empty(args.params.path)
    throw gina#core#exception#warn(printf(
          \ 'No filename is specified. Did you mean "Gina blame %s:"?',
          \ args.params.rev,
          \))
  endif

  call args.pop('--porcelain')
  call args.pop('--line-porcelain')
  call args.set('--incremental', 1)
  call args.set(1, substitute(args.params.rev, '^:0$', '', ''))
  call args.residual([args.params.path])
  return args.lock()
endfunction

function! s:call(range, args, mods) abort
  let git = gina#core#get_or_fail()
  let args = s:build_args(git, a:args)
  let mods = gina#util#contain_direction(a:mods)
        \ ? 'keepalt ' . a:mods
        \ : join(['keepalt', 'rightbelow', a:mods])
  let group = s:Group.new()

  " Content
  call s:open(mods, args.params.opener, args.params)
  call group.add()
  windo setlocal noscrollbind
  setlocal scrollbind nowrap
  augroup gina_command_blame_internal
    autocmd! * <buffer>
    autocmd WinLeave <buffer> call s:WinLeave()
    autocmd WinEnter <buffer> call s:WinEnter()
  augroup END
  " Navi
  let bufname = gina#core#buffer#bufname(git, 'blame', {
        \ 'treeish': args.params.treeish,
        \})
  call gina#core#buffer#open(bufname, {
        \ 'mods': 'leftabove',
        \ 'group': args.params.groups[1],
        \ 'opener': args.params.width . 'vsplit',
        \ 'cmdarg': args.params.cmdarg,
        \ 'range': 'all',
        \ 'line': args.params.line,
        \ 'callback': {
        \   'fn': function('s:init'),
        \   'args': [args],
        \ }
        \})
  call group.add()
  setlocal scrollbind
  call gina#util#syncbind()
  call gina#core#emitter#emit('command:called', s:SCHEME)
endfunction

function! s:open(mods, opener, params) abort
  if s:Opener.is_preview_opener(a:opener)
    throw gina#core#exception#warn(printf(
          \ 'An opener "%s" is not allowed.',
          \ a:opener,
          \))
  endif
  let treeish = gina#core#treeish#build(a:params.rev, a:params.path)
  execute printf(
        \ '%s Gina show %s %s %s %s %s',
        \ a:mods,
        \ a:params.cmdarg,
        \ gina#util#shellescape(a:opener, '--opener='),
        \ gina#util#shellescape(a:params.groups[0], '--group='),
        \ gina#util#shellescape(a:params.line, '--line='),
        \ gina#util#shellescape(treeish),
        \)
endfunction

function! s:init(args) abort
  call gina#core#meta#set('args', a:args)

  if exists('b:gina_initialized')
    return
  endif
  let b:gina_initialized = 1

  setlocal buftype=nofile
  setlocal bufhidden=wipe
  setlocal noswapfile
  setlocal nomodifiable
  " While navi must be vertical, set winfixwidth
  setlocal winfixwidth

  " Attach modules
  call gina#action#attach(function('s:get_candidates'))
  call gina#action#include('blame')
  call gina#action#include('browse')
  call gina#action#include('changes')
  call gina#action#include('compare')
  call gina#action#include('diff')
  call gina#action#include('show')

  augroup gina_command_blame_internal
    autocmd! * <buffer>
    autocmd BufReadCmd <buffer> call s:BufReadCmd()
    autocmd VimResized <buffer> call s:VimResized()

  augroup gina_command_blame_internal
    autocmd! * <buffer>
    autocmd BufReadCmd <buffer> call s:BufReadCmd()
    autocmd VimResized <buffer> call s:VimResized()
    autocmd WinLeave <buffer> call s:WinLeave()
    autocmd WinEnter <buffer> call s:WinEnter()
  augroup END
endfunction

function! s:WinLeave() abort
  let bufname = bufname('%')
  let scheme = gina#core#buffer#param(bufname, 'scheme')
  let alternate = substitute(
        \ bufname,
        \ ':' . scheme . '\>',
        \ ':' . (scheme ==# 'blame' ? 'show' : 'blame'),
        \ ''
        \)
  if bufwinnr(alternate) > 0
    call setbufvar(alternate, 'gina_syncbind_line', line('.'))
  endif
endfunction

function! s:WinEnter() abort
  if exists('b:gina_syncbind_line')
    call setpos('.', [0, b:gina_syncbind_line, col('.'), 0])
    unlet b:gina_syncbind_line
  endif
  syncbind
endfunction

function! s:BufReadCmd() abort
  let git = gina#core#get_or_fail()
  let args = gina#core#meta#get_or_fail('args')
  let pipe = gina#command#blame#pipe#incremental()
  let job = gina#process#open(git, args, pipe)
  let status = job.wait()
  if status
    throw gina#process#errormsg({
          \ 'args': job.args,
          \ 'status': status,
          \ 'content': pipe._stderr,
          \})
  endif
  call gina#core#meta#set('chunks', job.chunks)
  call gina#core#meta#set('revisions', job.revisions)
  call s:redraw_content()
  call gina#util#syncbind()
  setlocal filetype=gina-blame
endfunction

function! s:VimResized() abort
  call s:redraw_content()
  call gina#util#syncbind()
endfunction

function! s:redraw_content() abort
  let args = gina#core#meta#get_or_fail('args')
  let chunks = gina#core#meta#get_or_fail('chunks')
  let revisions = gina#core#meta#get_or_fail('revisions')
  let formatter = gina#command#blame#formatter#new(
        \ winwidth(0),
        \ args.params.rev,
        \ revisions,
        \)
  if exists('b:gina_blame_writer')
    call b:gina_blame_writer.kill()
  endif
  if len(chunks) < g:gina#command#blame#writer_threshold
    let content = []
    call map(copy(chunks), 'extend(content, formatter.format(v:val))')
    call gina#core#writer#assign_content(v:null, content)
  else
    " To improve UX, use writer for chunks over 1000 (e.g. vim/src/eval.c)
    let writer = gina#core#writer#new(s:writer)
    let writer.formatter = formatter
    call writer.start()
    call map(copy(chunks), 'writer.write(v:val)')
    call writer.stop()
    let b:gina_blame_writer = writer
  endif
endfunction

function! s:get_candidates(fline, lline) abort
  let args = gina#core#meta#get_or_fail('args')
  let chunks = gina#core#meta#get_or_fail('chunks')
  let revisions = gina#core#meta#get_or_fail('revisions')
  let fidx = s:binary_search(chunks, a:fline, 0, len(chunks) - 1)
  let lidx = s:binary_search(chunks, a:lline, 0, len(chunks) - 1)
  let candidates = map(
        \ range(fidx, lidx),
        \ 's:translate_candidate(args.params.rev, chunks[v:val], revisions)'
        \)
  return candidates
endfunction

function! s:binary_search(chunks, lnum, imin, imax) abort
  if a:imax < a:imin
    return v:null
  endif
  let imid = a:imin + (a:imax - a:imin) / 2
  let chunk = a:chunks[imid]
  if chunk.lnum > a:lnum
    return s:binary_search(a:chunks, a:lnum, a:imin, imid - 1)
  elseif (chunk.lnum + chunk.nlines - 1) < a:lnum
    return s:binary_search(a:chunks, a:lnum, imid + 1, a:imax)
  else
    return imid
  endif
endfunction

function! s:translate_candidate(rev, chunk, revisions) abort
  let chunk = copy(a:chunk)
  call extend(chunk, s:Dict.omit(a:revisions[chunk.revision], [
        \ 'lnum_from', 'lnum', 'nlines',
        \]))
  if chunk.revision =~# '^' . a:rev && has_key(chunk, 'previous')
    let rev = matchstr(chunk.previous, '^\S\+')
    let path = matchstr(chunk.previous, '^\S\+ \zs.*')
    let line = v:null
  else
    let rev = chunk.revision
    let path = chunk.filename
    let line = chunk.lnum_from
  endif
  return extend(chunk, {
        \ 'rev': rev,
        \ 'path': path,
        \ 'line': line,
        \})
endfunction


" Writer ---------------------------------------------------------------------
let s:writer = {}

function! s:writer.on_read(msg) abort
  if a:msg is# v:null
    retur a:msg
  endif
  let leading = a:msg.index == 0 ? [] : ['']
  return leading + self.formatter.format(a:msg)
endfunction


" Config ---------------------------------------------------------------------
call gina#config(expand('<sfile>'), {
      \ 'use_default_aliases': 1,
      \ 'use_default_mappings': 1,
      \ 'writer_threshold': 1000,
      \})
