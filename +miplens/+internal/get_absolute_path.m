function absPath = get_absolute_path(p)
%GET_ABSOLUTE_PATH   Resolve a path to its absolute canonical form.

f = java.io.File(p);
if ~f.isAbsolute()
    f = java.io.File(fullfile(pwd, p));
end
absPath = char(f.getCanonicalPath());

end
