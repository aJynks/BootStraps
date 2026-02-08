var saveFolder = new Folder( "e:\\Projects\\_Incremental Save" );
var saveExt = 'pdf';  
var saveSufixStart = '_';  
var saveSufixLength = 3;  
// End of user options   
  
var docName = decodeURI ( activeDocument.name );  
docName = docName.match( /(.*)(\.[^\.]+)/ ) ? docName = docName.match( /(.*)(\.[^\.]+)/ ) : docName = [ docName, docName, undefined ];  
var saveName = docName[ 1 ]; // activeDocument name with out ext  
var files = saveFolder.getFiles( saveName + '*.' + saveExt );// get an array of files matching doc name prefix  
  
var saveNumber = files.length + 1;  
//alert("New file number: " + zeroPad( saveNumber, saveSufixLength ));  
var saveFile = new File( saveFolder + '/' + saveName + '_' + zeroPad( saveNumber, saveSufixLength ) + '.' + saveExt );  
saveAsPDF("High Quality Print", false, false, 7, "U.S. Web Coated (SWOP) v2", false, "CGATS TR 001", saveFile, true, true, false, false); 
  
function zeroPad ( num, digit ) {   
   var tmp = num.toString();   
   while (tmp.length < digit) { tmp = "0" + tmp;}   
   return tmp;  
}

function saveAsPDF(pdfPresetFilename, pdfPreserveEditing, pdfOptimizeForWeb, pdfCompressionType, pdfDestinationProfileDescription, pdfIncludeProfile, pdfOutputConditionIdentifier, in2, copy, lowerCase, layers, embedProfiles) {
	function s2t(s) {
        return app.stringIDToTypeID(s);
    }
	var descriptor = new ActionDescriptor();
	var descriptor2 = new ActionDescriptor();
	descriptor2.putString( s2t( "pdfPresetFilename" ), pdfPresetFilename );
	descriptor2.putBoolean( s2t( "pdfPreserveEditing" ), pdfPreserveEditing );
	descriptor2.putBoolean( s2t( "pdfOptimizeForWeb" ), pdfOptimizeForWeb );
	descriptor2.putEnumerated( s2t( "pdfDownSample" ), s2t( "pdfDownSample" ), s2t( "none" ));
	descriptor2.putInteger( s2t( "pdfCompressionType" ), pdfCompressionType );
	descriptor2.putEnumerated( s2t( "pdfColorConversion" ), s2t( "pdfColorConversion" ), s2t( "name" ));
	descriptor2.putString( s2t( "pdfDestinationProfileDescription" ), pdfDestinationProfileDescription );
	descriptor2.putBoolean( s2t( "pdfIncludeProfile" ), pdfIncludeProfile );
	descriptor2.putString( s2t( "pdfOutputConditionIdentifier" ), pdfOutputConditionIdentifier );
	descriptor.putObject( s2t( "as" ), s2t( "photoshopPDFFormat" ), descriptor2 );
	descriptor.putPath( s2t( "in" ), in2 );
	descriptor.putInteger( s2t( "documentID" ), 862 );
	descriptor.putBoolean( s2t( "copy" ), copy );
	descriptor.putBoolean( s2t( "lowerCase" ), lowerCase );
	descriptor.putBoolean( s2t( "layers" ), layers );
	descriptor.putBoolean( s2t( "embedProfiles" ), embedProfiles );
	descriptor.putEnumerated( s2t( "saveStage" ), s2t( "saveStageType" ), s2t( "saveSucceeded" ));
	executeAction( s2t( "save" ), descriptor, DialogModes.NO );
}