import haxe.Exception;
import haxe.io.Path;
import checkstyle.checks.coding.CodeSimilarityCheck;
import checkstyle.config.Config;
import checkstyle.config.ConfigParser;
import checkstyle.config.ExcludeManager;
import checkstyle.reporter.ReporterManager;
import vscode.DiagnosticCollection;
import vscode.ExtensionContext;
import vscode.TextDocument;

using StringTools;

/**
 * This code is for the VSCode extension which integrates Haxe Checkstyle into the editor.
 * It implements highlighting and problem reporting based on the user's `checkstyle.json`,
 * displays checkstyle issues as diagnostics under the `Problems` tab, where they can be filtered,
 * adds JSON validation to ensure the user's `checkstyle.json` is formatted properly,
 * and adds code actions to automatically resolve certain issues.
 * 
 * Many of the classes and functions used here are hooks into VSCode's API, provided by the main Haxe extension.
 * @see https://vshaxe.github.io/vscode-extern/
 * 
 * The engine which evaluates Haxe and actually looks for the issues is implemented separately.
 * @see https://github.com/HaxeCheckstyle/haxe-checkstyle 
 */
class Main {
	/**
	 * The key where configuration options should be stored in `.vscode/settings.json`.
	 */
	static inline var MAIN_CONFIG_KEY = "haxecheckstyle";

	/**
	 * The extension will search for `checkstyle.json` and `checkstyle-excludes.json` config files
	 * in each directory in the file's path, up to and including the root of the workspace.
	 */
	static inline var CHECKSTYLE_JSON = "checkstyle.json";

	static inline var CHECKSTYLE_EXCLUDE_JSON = "checkstyle-excludes.json";

	/**
	 * `haxecheckstyle.configurationFile` determines where to get the `checkstyle.json` configuration from
	 * if the automated search does not locate an appropriate config.
	 */
	static inline var CONFIG_OPTION = "configurationFile";

	/**
	 * `haxecheckstyle.sourceFolders` holds an array of folder names,
	 * containing files where checkstyle should be applied on.
	 * Folders not listed here are ignored completely.
	 */
	static inline var SOURCE_FOLDERS = "sourceFolders";

	/**
	 * 
	 */
	static inline var EXTERNAL_SOURCE_ROOTS = "externalSourceRoots";

	/**
	 * In large workspaces, the extension won't be able to keep track of all your code
	 * to enforce the `CodeSimilarity` rule. This defaults to 100 files.
	 * Set `haxecheckstyle.codeSimilarityBufferSize` to change this.
	 */
	static inline var CODE_SIMILARITY_BUFFER_SIZE = "codeSimilarityBufferSize";

	var context:ExtensionContext;
	var diagnostics:DiagnosticCollection;
	var codeActions:CheckstyleCodeActions;

	/**
	 * The constructor function performs initialization for the VSCode integrations.
	 * @param ctx The extension context.
	 */
	function new(ctx) {
		context = ctx;
		diagnostics = Vscode.languages.createDiagnosticCollection("checkstyle");

		// Create and add a new provider for code actions.
		codeActions = new CheckstyleCodeActions();
		Vscode.languages.registerCodeActionsProvider("haxe", codeActions);

		// Add a callback to perform style checks upon saving and opening a document.
		Vscode.workspace.onDidSaveTextDocument(check);
		Vscode.workspace.onDidOpenTextDocument(check);

		// Now that the extension is initialized,
		// perform checkstyle in all visible text editors.
		for (editor in Vscode.window.visibleTextEditors) {
			check(editor.document);
		}
	}

	/**
	 * Perform style checks on the provided text document.
	 * @param event The document to perform the style checks on.
	 */
	@:access(checkstyle)
	function check(event:TextDocument) {
		var fileName = event.fileName;
		// Skip if not a haxe file.
		if (event.languageId != "haxe" || !sys.FileSystem.exists(fileName)) {
			return;
		}

		var rootFolder = determineRootFolder(fileName);
		if (rootFolder == null) {
			return;
		}

		// Initialize the Haxe checkstyle library.
		tokentree.TokenStream.MODE = Relaxed;
		var checker = new checkstyle.Main();
		checker.configParser.validateMode = ConfigValidateMode.RELAXED;
		addSourcePaths(checker.configParser);

		// Skip if the file is out of scope (according to the config).
		if (!fileInSourcePaths(fileName, rootFolder, checker.configParser.paths)) {
			return;
		}

		// Fetch the `haxecheckstyle` configuration from the VSCode workspace settings.
		var configuration = Vscode.workspace.getConfiguration(MAIN_CONFIG_KEY);

		// Manage the code similarity buffer.
		var codeSimilarityBufferSize:Int = 100;
		if (configuration.has(CODE_SIMILARITY_BUFFER_SIZE)) {
			codeSimilarityBufferSize = configuration.get(CODE_SIMILARITY_BUFFER_SIZE);
		}
		ExcludeManager.INSTANCE.clear();
		CodeSimilarityCheck.cleanupRingBuffer(codeSimilarityBufferSize);
		CodeSimilarityCheck.cleanupFile(fileName);

		// Load the checkstyle config from the current workspace.
		loadConfig(checker, fileName, rootFolder);

		var file:Array<checkstyle.CheckFile> = [{name: fileName, content: null, index: 0}];
		var reporter = new VSCodeReporter(1, checker.configParser.getCheckCount(), checker.checker.checks.length, null, false);
		reporter.fileNameFilter = fileName;
		ReporterManager.INSTANCE.clear();
		ReporterManager.INSTANCE.addReporter(reporter);

		// Perform the checkStyle checks.
		checker.checker.process(file);
		// Add any reported issues to the VSCode diagnostics list.
		// VSCode will later trigger the callback to build a set of code actions to perform.
		diagnostics.set(vscode.Uri.file(fileName), reporter.diagnostics);
	}

	/**
	 * Load the checkstyle config from the local directory.
	 */
	@:access(checkstyle)
	function loadConfig(checker:checkstyle.Main, fileName:String, rootFolder:String) {
		// use checkstyle.json from project folder
		var defaultPath = determineConfigFolder(fileName, rootFolder);
		if (defaultPath == null) {
			loadConfigFromSettings(checker, rootFolder);
			return;
		}

		try {
			checker.configPath = Path.join([defaultPath, CHECKSTYLE_JSON]);
			checker.configParser.loadConfig(checker.configPath);
			try {
				var excludeConfig = Path.join([defaultPath, CHECKSTYLE_EXCLUDE_JSON]);
				if (sys.FileSystem.exists(excludeConfig)) {
					checker.configParser.loadExcludeConfig(excludeConfig);
				}
			} catch (e:Exception) {
				// tolerate failures for exclude config
			}
			return;
		} catch (e:Exception) {
			checker.configPath = null;
		}
		// If we can't find the config, load the config using the path in the VSCode workspace settings.
		loadConfigFromSettings(checker, rootFolder);
	}

	/**
	 * Loads the Haxe checkstyles config from the value specified in VSCode settings,
	 * under `haxecheckstyle.configurationFile`.
	 */
	@:access(checkstyle)
	function loadConfigFromSettings(checker:checkstyle.Main, rootFolder:String) {
		// use config file set through vscode settings
		var configuration:vscode.WorkspaceConfiguration = Vscode.workspace.getConfiguration(MAIN_CONFIG_KEY);
		if (configuration.has(CONFIG_OPTION) && configuration.get(CONFIG_OPTION) != "") {
			try {
				var file = configuration.get(CONFIG_OPTION);
				if (sys.FileSystem.exists(file)) {
					checker.configPath = file;
				} else {
					checker.configPath = Path.join([rootFolder, file]);
				}
				checker.configParser.loadConfig(checker.configPath);
				return;
			} catch (e:Exception) {
				checker.configPath = null;
			}
		}
		// default use vscode-checkstyles own builtin config
		useInternalCheckstyleConfig(checker, rootFolder);
	}

	/**
	 * Move up the directory tree for a given file, and find the nearest `checkstyle.json` file.
	 */
	function determineConfigFolder(fileName:String, rootFolder:String):String {
		var path:String = Path.directory(fileName);

		while (path.length >= rootFolder.length) {
			var configFile:String = Path.join([path, CHECKSTYLE_JSON]);
			if (sys.FileSystem.exists(configFile)) {
				return path;
			}
			path = Path.normalize(Path.join([path, ".."]));
		}
		return null;
	}

	/**
	 * Load the default checkstyle config from the extension's resources folder.
	 */
	@:access(checkstyle)
	function useInternalCheckstyleConfig(checker:checkstyle.Main, rootFolder:String) {
		var config:Config = CompileTime.parseJsonFile("resources/default-checkstyle.json");
		try {
			checker.configParser.parseAndValidateConfig(config, rootFolder);
		} catch (e:Exception) {
			checker.configParser.addAllChecks();
		}
	}

	function determineRootFolder(fileName:String):String {
		if (Vscode.workspace.workspaceFolders == null) {
			return null;
		}
		for (i in 0...Vscode.workspace.workspaceFolders.length) {
			var workspaceFolder = Vscode.workspace.workspaceFolders[i];
			if (fileName.startsWith(workspaceFolder.uri.fsPath)) {
				return workspaceFolder.uri.fsPath;
			}
		}

		var configuration = Vscode.workspace.getConfiguration(MAIN_CONFIG_KEY);
		if (!configuration.has(EXTERNAL_SOURCE_ROOTS)) {
			return null;
		}
		var folders:Array<String> = configuration.get(EXTERNAL_SOURCE_ROOTS);
		if (folders == null) {
			return null;
		}
		for (folder in folders) {
			if (fileName.startsWith(folder)) {
				return folder;
			}
		}
		return null;
	}

	/**
	 * If the VSCode workspace's settings file contains a list of source folders,
	 * under the key `haxecheckstyle.sourceFolders`, add them to the config.
	 */
	function addSourcePaths(configParser:ConfigParser) {
		var configuration = Vscode.workspace.getConfiguration(MAIN_CONFIG_KEY);
		if (!configuration.has(SOURCE_FOLDERS)) {
			return;
		}
		var folders:Array<String> = configuration.get(SOURCE_FOLDERS);
		if (folders == null) {
			return;
		}
		for (folder in folders) {
			configParser.paths.push(folder);
		}
	}

	/**
	 * Utility function to check if a given file name is in one of the config's source folders.
	 * @return Whether the file is valid to check styles on.
	 */
	function fileInSourcePaths(fileName:String, rootFolder:String, paths:Array<String>):Bool {
		fileName = normalizePath(fileName);
		for (path in paths) {
			var rootPath = normalizePath(Path.join([rootFolder, path]));
			if (fileName.startsWith(rootPath)) {
				return true;
			}
		}
		return false;
	}

	/**
	 * If we are on Windows, paths are case insensitive.
	 */
	function normalizePath(path:String):String {
		path = Path.normalize(path);
		if (Sys.systemName() == "Windows") {
			path = path.toLowerCase();
		}
		return path;
	}

	@:keep
	@:expose("activate")
	static function main(context:ExtensionContext) {
		new Main(context);
	}
}
