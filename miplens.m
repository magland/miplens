function text = miplens(arg, varargin)
%MIPLENS   Get an AI-generated overview of (or answer a question about) a MATLAB package.
%
% Usage (command form — the preferred way to call it):
%   miplens export_fig
%   miplens export_fig what are the exported functions
%   miplens /path/to/package_dir
%
% Usage (function form):
%   miplens('export_fig')
%   miplens('export_fig', 'what are the exported functions?')
%
% If the first argument is an existing directory, its contents are read
% directly. Otherwise it is treated as a package name and resolved via
% mip's installed-package lookup.
%
% Any additional arguments are joined with spaces into a single query
% string. If no query is supplied, a default "give me an overview"
% prompt is used.
%
% The backend URL defaults to the deployed Cloudflare Worker and can be
% overridden with the MIPLENS_BACKEND_URL environment variable (e.g. to
% point at a local 'wrangler dev' instance).
%
% If called with no output argument, the result is printed.

if nargin < 1 || isempty(arg)
    error('miplens:noArg', 'A package directory or name is required.');
end

if isstring(arg)
    arg = char(arg);
end

if isfolder(arg)
    pkgDir = miplens.internal.get_absolute_path(arg);
    [~, displayName] = fileparts(pkgDir);
else
    [pkgDir, displayName] = miplens.internal.resolve_package_dir(arg);
end

query = '';
if ~isempty(varargin)
    parts = cell(1, numel(varargin));
    for i = 1:numel(varargin)
        p = varargin{i};
        if isstring(p)
            p = char(p);
        end
        if ~ischar(p)
            error('miplens:badQuery', ...
                  'Query arguments must be strings or char vectors.');
        end
        parts{i} = p;
    end
    query = strjoin(parts, ' ');
end

files = miplens.internal.collect_package_files(pkgDir);
if isempty(files)
    error('miplens:noFiles', ...
          'No .m or .md files found under "%s".', pkgDir);
end

result = miplens.internal.post_lens_request(displayName, files, query);

if nargout > 0
    text = result;
else
    fprintf('\n%s\n', result);
end

end
