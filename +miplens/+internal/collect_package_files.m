function files = collect_package_files(pkgDir)
%COLLECT_PACKAGE_FILES   Gather textual source files from a package directory.
%
% Returns a struct array with fields `path` (relative to pkgDir, forward
% slashes) and `content` (UTF-8 char vector). Collects .m, .md, .yaml,
% .yml, .txt, .json files and `README*`. Skips hidden directories and
% common build/VCS directories.

if ~isfolder(pkgDir)
    error('miplens:notADir', 'Not a directory: %s', pkgDir);
end

extensions = {'.m', '.md', '.yaml', '.yml', '.txt', '.json'};
skipDirs = {'.git', '.github', 'node_modules', 'build', 'dist', 'packages'};
maxBytesPerFile = 200 * 1024;

files = struct('path', {}, 'content', {});

stack = {pkgDir};
while ~isempty(stack)
    current = stack{end};
    stack(end) = [];

    entries = dir(current);
    for i = 1:length(entries)
        e = entries(i);
        if strcmp(e.name, '.') || strcmp(e.name, '..')
            continue
        end
        full = fullfile(current, e.name);

        if e.isdir
            if startsWith(e.name, '.') || any(strcmp(e.name, skipDirs))
                continue
            end
            stack{end+1} = full; %#ok<AGROW>
            continue
        end

        [~, base, ext] = fileparts(e.name);
        isReadme = startsWith(lower(base), 'readme');
        if ~any(strcmpi(ext, extensions)) && ~isReadme
            continue
        end

        if e.bytes > maxBytesPerFile
            continue
        end

        rel = strrep(full(length(pkgDir)+2:end), filesep, '/');
        content = readFileAsString(full);
        files(end+1).path = rel; %#ok<AGROW>
        files(end).content = content;
    end
end

end


function s = readFileAsString(path)
    fid = fopen(path, 'r', 'n', 'UTF-8');
    if fid < 0
        error('miplens:readFailed', 'Could not read: %s', path);
    end
    cleanup = onCleanup(@() fclose(fid));
    raw = fread(fid, inf, 'uint8=>uint8');
    s = native2unicode(raw(:)', 'UTF-8');
end
