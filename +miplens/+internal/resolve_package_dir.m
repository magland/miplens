function [pkgDir, displayName] = resolve_package_dir(pkgArg)
%RESOLVE_PACKAGE_DIR   Resolve a mip package argument to an on-disk directory.
%
% Replicates mip's own resolution logic without requiring mip to be on
% the MATLAB path. Accepts:
%   - bare name                         (e.g. 'memorygraph')
%   - local/<name>, fex/<name>, web/<name>
%   - <org>/<channel>/<name>            (implicit gh)
%   - gh/<org>/<channel>/<name>         (explicit gh)
%
% Bare-name resolution prefers gh/mip-org/core, then falls back to the
% first match alphabetically by FQN. Name matching is case-insensitive
% and treats '-' and '_' as equivalent.

parts = splitParts(pkgArg);

packagesDir = locatePackagesDir();

switch numel(parts)
    case 1
        [pkgDir, fqn] = findByBareName(packagesDir, parts{1});
        if isempty(pkgDir)
            error('miplens:packageNotFound', ...
                  'Package "%s" is not installed.', pkgArg);
        end
    case 2
        type = parts{1};
        if strcmp(type, 'gh')
            error('miplens:invalidPackageSpec', ...
                  'Invalid package spec: "%s".', pkgArg);
        end
        [pkgDir, onDisk] = findInstalledDir(fullfile(packagesDir, type), parts{2});
        if isempty(pkgDir)
            error('miplens:packageNotFound', ...
                  'Package "%s" is not installed.', pkgArg);
        end
        fqn = [type '/' onDisk];
    case 3
        [pkgDir, onDisk] = findInstalledDir( ...
            fullfile(packagesDir, 'gh', parts{1}, parts{2}), parts{3});
        if isempty(pkgDir)
            error('miplens:packageNotFound', ...
                  'Package "%s" is not installed.', pkgArg);
        end
        fqn = ['gh/' parts{1} '/' parts{2} '/' onDisk];
    case 4
        if ~strcmp(parts{1}, 'gh')
            error('miplens:invalidPackageSpec', ...
                  'Invalid package spec: "%s".', pkgArg);
        end
        [pkgDir, onDisk] = findInstalledDir( ...
            fullfile(packagesDir, 'gh', parts{2}, parts{3}), parts{4});
        if isempty(pkgDir)
            error('miplens:packageNotFound', ...
                  'Package "%s" is not installed.', pkgArg);
        end
        fqn = ['gh/' parts{2} '/' parts{3} '/' onDisk];
    otherwise
        error('miplens:invalidPackageSpec', ...
              'Invalid package spec: "%s".', pkgArg);
end

displayName = displayFqn(fqn);

end


function parts = splitParts(s)
    s = char(s);
    if contains(s, '@')
        s = extractBefore(s, max(strfind(s, '@')));
    end
    parts = strsplit(s, '/');
    parts = parts(~cellfun('isempty', parts));
    for i = 1:numel(parts)
        if ~isValidComponent(parts{i})
            error('miplens:invalidPackageSpec', ...
                  'Invalid component "%s" in package spec.', parts{i});
        end
    end
end


function tf = isValidComponent(s)
    tf = ~isempty(s) && ~strcmp(s, '.') && ~strcmp(s, '..') && ...
         all(ismember(s, ['a':'z' 'A':'Z' '0':'9' '-_.']));
end


function [pkgDir, fqn] = findByBareName(packagesDir, name)
    pkgDir = '';
    fqn = '';
    matches = {};  % {fqn, dir}

    if ~isfolder(packagesDir)
        return
    end

    top = listDirs(packagesDir);
    for i = 1:numel(top)
        topName = top{i};
        topPath = fullfile(packagesDir, topName);
        if strcmp(topName, 'gh')
            orgs = listDirs(topPath);
            for j = 1:numel(orgs)
                orgPath = fullfile(topPath, orgs{j});
                chans = listDirs(orgPath);
                for k = 1:numel(chans)
                    chanPath = fullfile(orgPath, chans{k});
                    [d, onDisk] = findInstalledDir(chanPath, name);
                    if ~isempty(d)
                        matches(end+1, :) = { ...
                            ['gh/' orgs{j} '/' chans{k} '/' onDisk], d}; %#ok<AGROW>
                    end
                end
            end
        else
            [d, onDisk] = findInstalledDir(topPath, name);
            if ~isempty(d)
                matches(end+1, :) = {[topName '/' onDisk], d}; %#ok<AGROW>
            end
        end
    end

    if isempty(matches)
        return
    end

    for i = 1:size(matches, 1)
        if startsWith(matches{i, 1}, 'gh/mip-org/core/')
            fqn = matches{i, 1};
            pkgDir = matches{i, 2};
            return
        end
    end

    [~, order] = sort(matches(:, 1));
    fqn = matches{order(1), 1};
    pkgDir = matches{order(1), 2};
end


function [pkgDir, onDiskName] = findInstalledDir(parentDir, name)
    pkgDir = '';
    onDiskName = '';
    if ~isfolder(parentDir)
        return
    end
    target = normalizeName(name);
    entries = listDirs(parentDir);
    for i = 1:numel(entries)
        if strcmp(normalizeName(entries{i}), target)
            onDiskName = entries{i};
            pkgDir = fullfile(parentDir, entries{i});
            return
        end
    end
end


function names = listDirs(parent)
    names = {};
    entries = dir(parent);
    for i = 1:numel(entries)
        if entries(i).isdir && ~startsWith(entries(i).name, '.')
            names{end+1} = entries(i).name; %#ok<AGROW>
        end
    end
end


function n = normalizeName(s)
    n = strrep(lower(char(s)), '-', '_');
end


function disp = displayFqn(fqn)
    if startsWith(fqn, 'gh/')
        disp = fqn(4:end);
    else
        disp = fqn;
    end
end


function packagesDir = locatePackagesDir()
    envRoot = getenv('MIP_ROOT');
    if ~isempty(envRoot)
        if ~isfolder(fullfile(envRoot, 'packages'))
            error('miplens:mipRootInvalid', ...
                  'MIP_ROOT="%s" has no "packages" subdirectory.', envRoot);
        end
        packagesDir = fullfile(envRoot, 'packages');
        return
    end

    % Navigate up from this file, assuming standard mip layout:
    %   <root>/packages/gh/<org>/<channel>/<pkg>/+miplens/+internal/resolve_package_dir.m
    thisDir = fileparts(mfilename('fullpath'));     % .../+internal
    d = fileparts(thisDir);                          % .../+miplens
    d = fileparts(d);                                % .../<pkg>
    d = fileparts(d);                                % .../<channel>
    d = fileparts(d);                                % .../<org>
    d = fileparts(d);                                % .../gh
    d = fileparts(d);                                % .../packages
    if isfolder(d) && endsWith(d, [filesep 'packages'])
        packagesDir = d;
        return
    end

    fallback = fullfile(userpath, 'mip', 'packages');
    if isfolder(fallback)
        packagesDir = fallback;
        return
    end

    error('miplens:mipRootNotFound', ...
          ['Could not locate the mip packages directory. ' ...
           'Set the MIP_ROOT environment variable to your mip root.']);
end
