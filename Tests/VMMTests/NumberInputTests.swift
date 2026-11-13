import XCTest
import SwiftUI
import AppKit
@testable import VMM

final class NumberInputTests:XCTestCase {
    func testPercentFractionalInputFormattingAndRoundTrip()throws {
        var value=0.5
        let input=NumberInput(title:"不透明度",value:Binding(get:{value},set:{value=$0}),range:0...1,percent:true)
        input.display.wrappedValue=12.345
        XCTAssertEqual(value,0.12345,accuracy:0.000000001)
        XCTAssertEqual(input.formatter.string(from:NSNumber(value:input.display.wrappedValue)),"12.345")
        XCTAssertEqual(input.increment,1)
        input.display.wrappedValue+=input.increment
        XCTAssertEqual(input.display.wrappedValue,13.345,accuracy:0.000001)
        var clip=Clip(kind:.text,name:"test",track:0,start:0,duration:1);clip.opacity=value
        let restored=try JSONDecoder().decode(Clip.self,from:JSONEncoder().encode(clip))
        XCTAssertEqual(restored.opacity,0.13345,accuracy:0.000000001)
        input.display.wrappedValue=100.001;XCTAssertEqual(value,1)
        input.display.wrappedValue = .nan;XCTAssertEqual(value,1)
        XCTAssertEqual(input.formatter.string(from:NSNumber(value:100)),"100.000")
    }
    @MainActor func testFieldEditorArrowsCommitTypedTextInDisplayUnitsAndRespectLimits() {
        var value=0.5
        let input=NumberInput(title:"不透明度",value:Binding(get:{value},set:{value=$0}),range:0...1,percent:true)
        let parent=NumberTextField(value:input.display,formatter:input.formatter,range:0...100,title:"不透明度",points:12)
        let delegate=parent.makeCoordinator(),field=NSTextField(string:"12.345"),editor=NSTextView()
        XCTAssertTrue(delegate.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(value,0.13345,accuracy:0.000001);XCTAssertEqual(field.stringValue,"13.345")
        XCTAssertTrue(delegate.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(value,0.12345,accuracy:0.000001)
        field.stringValue="99.999";_=delegate.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(value,1);field.stringValue="0.000";_=delegate.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveDown(_:)));XCTAssertEqual(value,0)
        field.stringValue="25.125";_=delegate.control(field,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)));XCTAssertEqual(value,0.25125,accuracy:0.000001)
        XCTAssertFalse(delegate.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveLeft(_:))))
        field.isEnabled=false;XCTAssertFalse(delegate.control(field,textView:editor,doCommandBy:#selector(NSResponder.moveUp(_:))))
    }
    func testChromaCachePreservesFinePercentageChanges() {
        let renderer=EffectRenderer()
        let first=renderer.cube(color:"00FF00",tolerance:0.12345)
        let second=renderer.cube(color:"00FF00",tolerance:0.12346)
        XCTAssertNotEqual(first,second)
        XCTAssertEqual(second,EffectRenderer().cube(color:"00FF00",tolerance:0.12346))
    }
    func testNegativePercentAndUnitSteps() {
        var value=0.0
        let position=NumberInput(title:"X位置",value:Binding(get:{value},set:{value=$0}),range:-2...3,percent:true)
        position.display.wrappedValue = -12.345;XCTAssertEqual(value,-0.12345,accuracy:0.000000001)
        position.display.wrappedValue = -12.3456;XCTAssertEqual(position.display.wrappedValue,-12.346,accuracy:0.000001)
        let outline=NumberInput(title:"縁の太さ",value:Binding(get:{value},set:{value=$0}),range:0...20,unit:"%")
        outline.display.wrappedValue=3.123;XCTAssertEqual(value,3.123,accuracy:0.000001)
        XCTAssertEqual(outline.increment,1)
        XCTAssertEqual(outline.formatter.string(from:NSNumber(value:value)),"3.123")
        let time=NumberInput(title:"秒",value:Binding(get:{value},set:{value=$0}),range:0...100,step:1.0/30)
        time.display.wrappedValue=1.0/30;XCTAssertEqual(value,1.0/30,accuracy:0.000000001);XCTAssertEqual(time.increment,1)
    }
}
